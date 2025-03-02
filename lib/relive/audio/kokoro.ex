defmodule Relive.Audio.Kokoro do
  use Membrane.Filter

  alias Membrane.RawAudio
  alias Relive.Audio.RawText

  require Logger

  @format %RawAudio{
    sample_format: :f32le,
    sample_rate: 24000,
    channels: 1
  }

  def_input_pad(:input,
    availability: :always,
    flow_control: :manual,
    demand_unit: :buffers,
    accepted_format: RawText
  )

  def_output_pad(:output,
    availability: :always,
    flow_control: :manual,
    accepted_format: %RawAudio{
      sample_format: :f32le,
      sample_rate: 24000,
      channels: 1
    }
  )

  @model_url "https://huggingface.co/onnx-community/Kokoro-82M-ONNX/resolve/main/onnx/model.onnx?download=true"
  @impl true
  def handle_init(_ctx, _mod) do
    model_path = ensure_model()
    ensure_voice()

    kokoro = Kokoro.new(model_path, :code.priv_dir(:relive))

    state = %{model: kokoro}
    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    IO.puts("playing...")
    {[demand: {:input, 1}, stream_format: {:output, @format}], state}
    # {[demand: {:input, 1}], state}
  end

  @impl true
  def handle_stream_format(_, _stream_format, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    IO.puts("demand buffers...")
    # {[demand: {:input, size}, stream_format: {:output, @format}], state}
    {[demand: {:input, size}], state}
  end

  def handle_demand(:output, _size, :bytes, _ctx, state) do
    IO.puts("demand bytes...")
    {[demand: {:input, 1}], state}
  end

  @impl true
  def handle_buffer(
        :input,
        %Membrane.Buffer{payload: data},
        _ctx,
        state
      ) do
    IO.puts("processing...")

    text =
      data
      |> Enum.map(& &1.text)
      |> Enum.join(" ")
      |> String.trim()

    Logger.info("Processing text: #{text}")

    binary = Kokoro.create_audio_binary(state.model, text, "voice", 1.0)

    buffer = %Membrane.Buffer{
      metadata: %{},
      payload: binary
    }

    {[buffer: {:output, buffer}], state}
  end

  @impl true
  def handle_info(_, _ctx, state) do
    IO.puts("info...")
    {[], state}
  end

  defp ensure_model do
    model_path =
      :relive
      |> :code.priv_dir()
      |> Path.join("kokoro.onnx")

    case File.stat(model_path) do
      {:ok, %{type: :regular}} ->
        :ok

      {:error, :enoent} ->
        Req.get!(@model_url, into: File.stream!(model_path))
    end

    model_path
  end

  @voice_url "https://huggingface.co/onnx-community/Kokoro-82M-ONNX/resolve/main/voices/bm_george.bin?download=true"
  defp ensure_voice do
    path =
      :relive
      |> :code.priv_dir()
      |> Path.join("voice.bin")

    case File.stat(path) do
      {:ok, %{type: :regular}} ->
        :ok

      {:error, :enoent} ->
        Req.get!(@voice_url, into: File.stream!(path))
    end

    path
  end
end
