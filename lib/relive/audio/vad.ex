defmodule Relive.Audio.VAD do
  use Membrane.Filter

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

  def_input_pad(:input,
    availability: :always,
    flow_control: :manual,
    demand_unit: :buffers,
    accepted_format: Membrane.RawAudio
  )

  def_output_pad(:output,
    availability: :always,
    flow_control: :manual,
    accepted_format: Membrane.RawAudio
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
      buffered: [],
      speaking?: false
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
  def handle_buffer(:input, %Membrane.Buffer{payload: data} = buffer, _context, state) do
    %{n: n, sr: sr, c: c, h: h} = state.run_state
    buffered = [state.buffered, data]

    if IO.iodata_length(buffered) >= state.bytes do
      data = IO.iodata_to_binary(buffered)

      input =
        data
        |> Nx.from_binary(:f32)
        |> List.wrap()
        |> Nx.stack()

      {output, hn, cn} = Ortex.run(state.model, {input, sr, h, c})
      prob = output |> Nx.squeeze() |> Nx.to_number()

      run_state = %{c: cn, h: hn, n: n + 1, sr: sr}
      state = %{state | run_state: run_state, buffered: []}

      actions =
        [demand: {:input, 1}]

      is_speech? = prob > state.opts.threshold

      {change, state} =
        cond do
          state.speaking? and is_speech? ->
            {nil, state}

          state.speaking? and not is_speech? ->
            {:stop, %{state | speaking?: false}}

          not state.speaking? and is_speech? ->
            {:start, %{state | speaking?: true}}

          not state.speaking? and not is_speech? ->
            {nil, state}
        end

      send_buffer =
        case {is_speech?, state.opts.filter?, state.opts.fill_mode} do
          {true, _, _} ->
            buffer

          {_, false, _} ->
            buffer

          {false, true, :cut} ->
            Logger.info("Cutting buffer...")
            nil

          {false, true, :silence} ->
            Logger.info("Padding silence...")
            buffer_size = byte_size(buffer.payload) * 8
            %{buffer | payload: <<0::size(buffer_size)>>}
        end

      actions =
        if change do
          [{:notify_parent, {:speaking, change, prob}} | actions]
        else
          actions
        end

      actions =
        if send_buffer do
          [{:buffer, {:output, send_buffer}}]
        else
          actions
        end

      {actions, state}
    else
      %{state | buffered: buffered}
      {[demand: {:input, 1}], state}
    end
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
