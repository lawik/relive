defmodule Relive.Audio.Whisper do
  use Membrane.Filter

  alias Membrane.RawAudio
  alias Relive.Audio.RawText

  require Logger

  def_options(
    serving: [
      spec: atom() | pid(),
      description: "Which serving to use for transcription."
    ]
  )

  def_input_pad(:input,
    availability: :always,
    flow_control: :manual,
    demand_unit: :buffers,
    accepted_format: RawAudio
  )

  def_output_pad(:output,
    availability: :always,
    flow_control: :manual,
    demand_unit: :buffers,
    accepted_format: RawText
  )

  @impl true
  def handle_init(_ctx, mod) do
    state = %{opts: mod}
    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[demand: {:input, 1}, stream_format: {:output, %RawText{}}], state}
  end

  @impl true
  def handle_stream_format(_, _stream_format, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {[demand: {:input, size}], state}
  end

  @impl true
  def handle_buffer(
        :input,
        %Membrane.Buffer{payload: data},
        %{pads: %{input: %{stream_format: %{channels: ch, sample_rate: sr}}}} = _ctx,
        state
      ) do
    IO.puts("buffer to whisper")
    bits = byte_size(data) * 8

    if data != <<0::size(bits)>> do
      audio = to_audio(data, ch, sr)
      %{chunks: chunks} = transcribe!(state.opts.serving, audio)
      # Logger.info("Chunks: #{inspect(chunks, pretty: true)}")
      text = to_raw_text(chunks)

      if is_common_madness(text) do
        {[], state}
      else
        new_buffer = %Membrane.Buffer{payload: text}
        {[notify_parent: {:transcript, text}, buffer: {:output, new_buffer}], state}
      end
    else
      # #Logger.info("Silence...")
      {[], state}
    end
  end

  defp is_common_madness(text) do
    text
    |> String.trim()
    |> String.downcase()
    |> case do
      "you" -> true
      "thank you" -> true
      _ -> false
    end
  end

  def serving(model \\ "base") do
    {:ok, whisper} = Bumblebee.load_model({:hf, "openai/whisper-#{model}"})
    {:ok, featurizer} = Bumblebee.load_featurizer({:hf, "openai/whisper-#{model}"})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, "openai/whisper-#{model}"})
    {:ok, generation_config} = Bumblebee.load_generation_config({:hf, "openai/whisper-#{model}"})

    case :os.type() do
      {:unix, :darwin} ->
        Bumblebee.Audio.speech_to_text_whisper(whisper, featurizer, tokenizer, generation_config,
          task: :transcribe,
          language: "en"
        )

      _ ->
        Bumblebee.Audio.speech_to_text_whisper(whisper, featurizer, tokenizer, generation_config,
          defn_options: [compiler: EXLA],
          task: :transcribe,
          language: "en"
        )
    end
  end

  def warmup do
    blank = for _ <- 1..16000, into: <<>>, do: <<0, 0, 0, 0>>

    audio =
      blank
      |> Nx.from_binary(:f32)
      |> Nx.reshape({:auto, 1})
      |> Nx.mean(axes: [1])

    {t, _} =
      :timer.tc(fn ->
        Nx.Serving.batched_run(Relive.Whisper, audio)
      end)

    Logger.info("Warmed up whisper in #{t / 1000}ms")
  end

  defp to_audio(raw_pcm_32_or_wav, channels, sampling_rate) do
    %{
      data: raw_pcm_32_or_wav,
      num_channels: channels,
      sampling_rate: sampling_rate
    }
  end

  defp transcribe!(name, audio) do
    duration = byte_size(audio.data) / 2 / 4 / audio.sampling_rate

    audio =
      audio.data
      |> Nx.from_binary(:f32)
      |> Nx.reshape({:auto, audio.num_channels})
      |> Nx.mean(axes: [1])

    {t, output} =
      :timer.tc(fn ->
        Nx.Serving.batched_run(name, audio)
      end)

    Logger.info("Transcribed #{round(duration * 1000)}ms in #{t / 1000}ms")
    output
  end

  defp to_raw_text(chunks) do
    chunks
    |> Enum.map(& &1.text)
    |> Enum.join(" ")
    |> String.trim()
  end
end
