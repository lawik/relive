defmodule Relive.Audio.VAD do
  use Membrane.Filter

  alias Membrane.RawAudio

  require Logger

  def_options(
    threshold: [
      spec: float(),
      default: 0.5,
      description:
        "Confidence value for the model that something is speech. 0.0 = not speech, 1.0 = speech"
    ],
    chunk_ms: [
      spec: integer(),
      default: 100,
      description: "Minimal size of chunk to feed the VAD. Minimum: 100, Default: 100"
    ],
    chunk_tolerance: [
      spec: integer(),
      default: 1,
      description:
        "Number of chunks with gap in speech to still consider a single section of speec. Default: 1"
    ],
    max_chunks: [
      spec: integer(),
      default: 20,
      description: "Max numbers of chunks to buffer before sending. Default: 20"
    ]
  )

  @format %RawAudio{
    sample_format: :f32le,
    sample_rate: 16000,
    channels: 1
  }

  def_input_pad(:input,
    availability: :always,
    flow_control: :manual,
    demand_unit: :buffers,
    accepted_format: %RawAudio{
      sample_format: :f32le,
      sample_rate: 16000,
      channels: 1
    }
  )

  def_output_pad(:output,
    availability: :always,
    flow_control: :manual,
    demand_unit: :buffers,
    accepted_format: RawAudio
  )

  @model_url "https://raw.githubusercontent.com/snakers4/silero-vad/v4.0stable/files/silero_vad.onnx"

  @impl true
  def handle_init(_ctx, mod) do
    model = ensure_model()

    sr = Nx.tensor(@format.sample_rate, type: :s64, backend: Nx.BinaryBackend)

    init_state = %{
      h: Nx.broadcast(0.0, {2, 1, 64}),
      c: Nx.broadcast(0.0, {2, 1, 64}),
      n: 0,
      sr: sr
    }

    state = %{
      opts: mod,
      run_state: init_state,
      model: model,
      out_buffer: nil,
      held_buffer: [],
      buffered: [],
      probability: 0.0,
      status: {:not_speaking, 0},
      chunks: 0
    }

    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[demand: {:input, 1}], state}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {[demand: {:input, size}], state}
  end

  @impl true
  def handle_buffer(
        :input,
        %Membrane.Buffer{payload: data},
        _ctx,
        state
      ) do
    buffered = [state.buffered, data]

    state = %{state | chunks: state.chunks + 1}

    # Assumes we are getting the correct size of buffer on the input

    {[], state}
    |> buffer(buffered)
    |> process()
    |> evaluate()
    |> filter()
    |> notify()
    |> demand_next()
  end

  defp buffer({actions, state}, buffered) do
    {actions, %{state | buffered: buffered}}
  end

  defp process({actions, state}) do
    %{n: n, sr: sr, c: c, h: h} = state.run_state
    data = IO.iodata_to_binary(state.buffered)

    input =
      data
      |> Nx.from_binary(:f32, backend: Nx.BinaryBackend)
      |> List.wrap()
      |> Nx.stack()

    {_t, {output, hn, cn}} =
      :timer.tc(fn ->
        Ortex.run(state.model, {input, sr, h, c})
      end)

    # #Logger.info("Processed #{byte_size(data)} bytes in #{t / 1000}ms")
    prob = output |> Nx.squeeze() |> Nx.to_number()

    run_state = %{c: cn, h: hn, n: n + 1, sr: sr}

    {actions, %{state | run_state: run_state, probability: prob}}
  end

  defp evaluate({actions, state}) do
    speaking? = state.probability > state.opts.threshold

    status =
      case {speaking?, state.status} do
        {true, {:not_speaking, _}} ->
          {:speaking, 0}

        {true, {:speaking, chunks_elapsed}} ->
          {:speaking, chunks_elapsed + 1}

        {false, {:not_speaking, chunks_elapsed}} ->
          {:not_speaking, chunks_elapsed + 1}

        {false, {:speaking, _}} ->
          {:not_speaking, 0}
      end

    {actions, %{state | status: status}}
  end

  defp filter({actions, state}) do
    tolerance = state.opts.chunk_tolerance
    buffer_size = IO.iodata_length(state.buffered)

    state =
      if state.chunks >= state.opts.max_chunks do
        IO.puts("VAD reached max chunks: #{state.opts.max_chunks}")
        send_buffer(state)
      else
        case state.status do
          {:not_speaking, count} when count == tolerance + 1 ->
            if buffer_size > 0 do
              IO.puts("Sending voice...")
              send_buffer(state)
            else
              hold_buffer(state)
            end

          {:not_speaking, count} when count > tolerance ->
            # Continuously empty the non-speaking buffer
            drop_buffer(state)

          {:not_speaking, _} ->
            hold_buffer(state)

          {:speaking, _count} ->
            # Keep buffer building up whether speaking or not_speaking within tolerance
            hold_buffer(state)
        end
      end

    actions =
      if state.out_buffer do
        [{:buffer, {:output, to_buffer(state.out_buffer)}} | actions]
      else
        actions
      end

    {actions, state}
  end

  defp send_buffer(state) do
    IO.puts("sending")

    %{
      state
      | out_buffer: IO.iodata_to_binary([state.held_buffer, state.buffered]),
        held_buffer: [],
        buffered: [],
        chunks: 0
    }
  end

  defp hold_buffer(state) do
    %{state | out_buffer: nil, held_buffer: [state.held_buffer, state.buffered], buffered: []}
  end

  defp drop_buffer(state) do
    %{state | out_buffer: nil, held_buffer: [], buffered: [], chunks: 0}
  end

  defp notify({actions, state}) do
    actions =
      case state.status do
        {:not_speaking, 0} ->
          [{:notify_parent, {:speaking, :stop, state.probability}} | actions]

        {:speaking, 0} ->
          [{:notify_parent, {:speaking, :start, state.probability}} | actions]

        _ ->
          actions
      end

    {actions, state}
  end

  defp demand_next({actions, state}) do
    {[{:demand, {:input, 1}} | actions], state}
  end

  defp to_buffer(data) do
    %Membrane.Buffer{payload: IO.iodata_to_binary(data)}
  end

  defp ensure_model do
    model_path =
      :relive
      |> :code.priv_dir()
      |> Path.join("silero_vad.onnx")

    case File.stat(model_path) do
      {:ok, %{type: :regular}} ->
        :ok

      {:error, :enoent} ->
        Req.get!(@model_url, into: File.stream!(model_path))
    end

    Ortex.load(model_path)
  end

  def mono_samples(chunk_ms) do
    min_ms = max(chunk_ms, 100)
    round(min_ms * (@format.sample_rate / 1000))
  end
end
