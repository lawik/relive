defmodule Relive.Audio.VAD do
  use Membrane.Filter

  alias Membrane.RawAudio

  require Logger

  def_options(
    filter?: [
      spec: boolean(),
      default: true,
      description: "Parts without voice are removed from the stream."
    ],
    fill_mode: [
      spec: :cut | :silence,
      default: :silence,
      description: "Create breaks in stream or pad filtered out parts with silence."
    ],
    buffer?: [
      spec: boolean(),
      default: true,
      description: "Buffer until speech is no longer detected. Default: true"
    ],
    delay?: [
      spec: boolean(),
      default: true,
      description:
        "Delay audio by 1 chunk (typically 100ms) more when filtering to smooth out the start? Only applies if filtering. Default: true"
    ],
    tail?: [
      spec: boolean(),
      default: true,
      description:
        "Pass through 1 additional chunk (typically 100ms) more when filtering to smooth out the end? Only applies if filtering. Default: true"
    ],
    notify?: [
      spec: boolean(),
      default: true,
      description: "Whether to send notifications to the parent pipeline on talk stop and start."
    ],
    threshold: [
      spec: float(),
      default: 0.5,
      description:
        "Confidence value for the model that something is speech. 0.0 = not speech, 1.0 = speech"
    ],
    log?: [
      spec: boolean(),
      default: false,
      description: "Emit logs continuously."
    ]
  )

  # TODO: change all to use auto flow_control
  def_input_pad(:input,
    availability: :always,
    flow_control: :manual,
    demand_unit: :buffers,
    accepted_format: RawAudio
  )

  def_output_pad(:output,
    availability: :always,
    flow_control: :manual,
    accepted_format: RawAudio
  )

  @model_url "https://raw.githubusercontent.com/snakers4/silero-vad/v4.0stable/files/silero_vad.onnx"

  @impl true
  def handle_init(_ctx, mod) do
    model = ensure_model()

    min_ms = 100

    sample_rate_hz = 16000
    sr = Nx.tensor(sample_rate_hz, type: :s64)
    n_samples = min_ms * (sample_rate_hz / 1000)

    bytes_per_chunk = n_samples * 2

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
      bytes: bytes_per_chunk,
      delay_buffer: nil,
      out_buffer: nil,
      buffered: [],
      probability: 0.0,
      status: {:not_speaking, 0}
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

    if buffer_ready?(state, buffered) do
      {[], state}
      |> buffer(buffered)
      |> demand_next()
      |> process()
      |> clear_buffer()
      |> evaluate()
      |> filter()
      |> notify()
    else
      {[], state}
      |> buffer(buffered)
      |> demand_next()
    end
  end

  defp buffer_ready?(state, buffered) do
    IO.iodata_length(buffered) >= state.bytes
  end

  defp buffer({actions, state}, buffered) do
    {actions, %{state | buffered: buffered}}
  end

  defp demand_next({actions, state}) do
    {[{:demand, {:input, 1}} | actions], state}
  end

  defp process({actions, state}) do
    %{n: n, sr: sr, c: c, h: h} = state.run_state
    data = IO.iodata_to_binary(state.buffered)

    input =
      data
      |> Nx.from_binary(:f32)
      |> List.wrap()
      |> Nx.stack()

    {t, {output, hn, cn}} =
      :timer.tc(fn ->
        Ortex.run(state.model, {input, sr, h, c})
      end)

    Logger.info("Processed #{byte_size(data)} bytes in #{t / 1000}ms")
    prob = output |> Nx.squeeze() |> Nx.to_number()

    run_state = %{c: cn, h: hn, n: n + 1, sr: sr}
    {actions, %{state | run_state: run_state, probability: prob}}
  end

  defp clear_buffer({actions, %{opts: %{buffer?: true, delay?: delay?}} = state}) do
    # Keep buffer, disregard out_buffer and delay_buffer
    if state.out_buffer && delay? do
      {actions, %{state | delay_buffer: state.out_buffer, out_buffer: nil}}
    else
      {actions, state}
    end
  end

  defp clear_buffer({actions, %{opts: %{filter?: true, delay?: true}} = state}) do
    {actions, %{state | delay_buffer: state.out_buffer, out_buffer: state.buffered, buffered: []}}
  end

  defp clear_buffer({actions, state}) do
    {actions, %{state | out_buffer: state.buffered, buffered: []}}
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

  defp filter({actions, %{opts: %{filter?: false}} = state}) do
    # Filtering is off, always pass output
    actions = [{:buffer, {:output, to_buffer(state.out_buffer)}} | actions]
    {actions, state}
  end

  defp filter({actions, %{opts: %{delay?: delay?, tail?: tail?, buffer?: buffer?}} = state}) do
    state =
      case state.status do
        {:not_speaking, 0} ->
          # Just stopped speaking, if tail is enabled, send that anyway
          if tail? do
            state
          else
            out_buffer_fill(state)
          end

        {:not_speaking, count} ->
          if buffer? do
            IO.inspect({:not_speaking, count, IO.iodata_length(state.buffered)},
              label: "not speaking"
            )

            if count > 1 and IO.iodata_length(state.buffered) > 0 do
              out_buffer_fill(state)
            else
              IO.inspect(count, label: "still buffering")
              state
            end
          else
            out_buffer_fill(state)
          end

        {:speaking, _} ->
          state
      end

    actions =
      if delay? do
        if state.delay_buffer do
          [{:buffer, {:output, to_buffer(state.delay_buffer)}} | actions]
        else
          actions
        end
      else
        if state.out_buffer do
          [{:buffer, {:output, to_buffer(state.out_buffer)}} | actions]
        else
          actions
        end
      end

    {actions, state}
  end

  defp notify({actions, state}) do
    if state.opts.notify? do
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
    else
      {actions, state}
    end
  end

  defp to_buffer(data) do
    %Membrane.Buffer{payload: IO.iodata_to_binary(data)}
  end

  defp out_buffer_fill(%{opts: %{buffer?: true}} = state) do
    out_buffer = IO.iodata_to_binary(state.buffered)
    IO.puts("Flushing buffer of #{byte_size(out_buffer)} bytes")

    %{state | out_buffer: out_buffer, buffered: []}
  end

  defp out_buffer_fill(state) do
    buffer_size = IO.iodata_length(state.out_buffer) * 8

    out_buffer =
      case state.opts.fill_mode do
        :silence ->
          <<0::size(buffer_size)>>

        :cut ->
          nil
      end

    %{state | out_buffer: out_buffer}
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
end
