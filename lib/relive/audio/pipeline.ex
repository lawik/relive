defmodule Relive.Audio.Pipeline do
  use Membrane.Pipeline

  alias Relive.Audio.VAD

  alias Membrane.Audiometer.Peakmeter
  alias Membrane.FFmpeg.SWResample
  alias Membrane.PortAudio

  require Logger

  def start_link(opts) do
    Membrane.Pipeline.start_link(__MODULE__, opts)
  end

  @default_peaks_per_second 60

  @impl true
  def handle_init(_ctx, opts) do
    # Setup the flow of the data
    # Stream from file
    spec = children(opts[:variant] || :default, opts)

    {[spec: spec], %{amps: %{peak_1: [], peak_2: []}, clock_started?: false}}
  end

  def variants do
    [:default, :step_0, :step_1, :step_2, :step_3, :step_4, :step_5]
  end

  @chunk_ms 200
  def children(:default, opts) do
    peaks_per_second = Keyword.get(opts, :peaks_per_second, @default_peaks_per_second)

    peak_interval =
      round(1000 / peaks_per_second)

    system_prompt = Keyword.get(opts, :system_prompt, "")

    child(:source, %PortAudio.Source{
      channels: 1,
      # sample_format: :s16le,
      sample_format: :f32le,
      sample_rate: 16000,
      portaudio_buffer_size: VAD.mono_samples(@chunk_ms)
    })
    |> child(:peak_1, %Peakmeter{
      # We set this interval to ensure a reasonable pace of notifications
      interval: Membrane.Time.milliseconds(peak_interval)
    })
    |> child(:vad, %VAD{chunk_tolerance: 2, chunk_ms: @chunk_ms, max_chunks: 100})
    |> child(:peak_2, %Peakmeter{
      interval: Membrane.Time.milliseconds(peak_interval)
    })
    |> child(:transcribe, %Relive.Audio.Whisper{serving: Relive.Whisper})
    |> child(:assistant, %Relive.LLM{serving: Relive.LLM, system_prompt: system_prompt})
    |> child(:voice, %Relive.Audio.Kokoro{})
    |> child(:converter, %SWResample.Converter{
      input_stream_format: %Membrane.RawAudio{
        sample_format: :f32le,
        sample_rate: 24000,
        channels: 1
      },
      output_stream_format: %Membrane.RawAudio{
        sample_format: :f32le,
        sample_rate: 16000,
        channels: 1
      }
    })
    |> child(:output, Membrane.PortAudio.Sink)
  end

  def children(:step_0, _opts) do
    child(:source, %PortAudio.Source{
      channels: 1,
      # sample_format: :s16le,
      sample_format: :f32le,
      sample_rate: 16000,
      portaudio_buffer_size: VAD.mono_samples(@chunk_ms)
    })
    |> child(:output, Membrane.PortAudio.Sink)
  end

  def children(:step_1, _opts) do
    child(:source, %PortAudio.Source{
      channels: 1,
      # sample_format: :s16le,
      sample_format: :f32le,
      sample_rate: 16000,
      portaudio_buffer_size: VAD.mono_samples(@chunk_ms)
    })
    |> child(:transcribe, %Relive.Audio.Whisper{serving: Relive.Whisper})
    |> child(:output, Membrane.Fake.Sink)
  end

  def children(:step_2, opts) do
    peaks_per_second = Keyword.get(opts, :peaks_per_second, @default_peaks_per_second)

    peak_interval =
      round(1000 / peaks_per_second)

    child(:source, %PortAudio.Source{
      channels: 1,
      # sample_format: :s16le,
      sample_format: :f32le,
      sample_rate: 16000,
      portaudio_buffer_size: VAD.mono_samples(@chunk_ms)
    })
    |> child(:peak_1, %Peakmeter{
      # We set this interval to ensure a reasonable pace of notifications
      interval: Membrane.Time.milliseconds(peak_interval)
    })
    |> child(:transcribe, %Relive.Audio.Whisper{serving: Relive.Whisper})
    |> child(:output, Membrane.Fake.Sink)
  end

  def children(:step_3, opts) do
    peaks_per_second = Keyword.get(opts, :peaks_per_second, @default_peaks_per_second)

    peak_interval =
      round(1000 / peaks_per_second)

    child(:source, %PortAudio.Source{
      channels: 1,
      # sample_format: :s16le,
      sample_format: :f32le,
      sample_rate: 16000,
      portaudio_buffer_size: VAD.mono_samples(@chunk_ms)
    })
    |> child(:peak_1, %Peakmeter{
      # We set this interval to ensure a reasonable pace of notifications
      interval: Membrane.Time.milliseconds(peak_interval)
    })
    |> child(:vad, %VAD{chunk_tolerance: 2, chunk_ms: @chunk_ms, max_chunks: 100})
    |> child(:peak_2, %Peakmeter{
      interval: Membrane.Time.milliseconds(peak_interval)
    })
    |> child(:transcribe, %Relive.Audio.Whisper{serving: Relive.Whisper})
    |> child(:output, Membrane.Fake.Sink)
  end

  def children(:step_4, opts) do
    peaks_per_second = Keyword.get(opts, :peaks_per_second, @default_peaks_per_second)

    peak_interval =
      round(1000 / peaks_per_second)

    child(:source, %PortAudio.Source{
      channels: 1,
      # sample_format: :s16le,
      sample_format: :f32le,
      sample_rate: 16000,
      portaudio_buffer_size: VAD.mono_samples(@chunk_ms)
    })
    |> child(:peak_1, %Peakmeter{
      # We set this interval to ensure a reasonable pace of notifications
      interval: Membrane.Time.milliseconds(peak_interval)
    })
    |> child(:vad, %VAD{chunk_tolerance: 1, chunk_ms: 100, max_chunks: 100})
    |> child(:peak_2, %Peakmeter{
      interval: Membrane.Time.milliseconds(peak_interval)
    })
    |> child(:transcribe, %Relive.Audio.Whisper{serving: Relive.Whisper})
    |> child(:voice, %Relive.Audio.Kokoro{})
    |> child(:converter, %SWResample.Converter{
      input_stream_format: %Membrane.RawAudio{
        sample_format: :f32le,
        sample_rate: 24000,
        channels: 1
      },
      output_stream_format: %Membrane.RawAudio{
        sample_format: :f32le,
        sample_rate: 16000,
        channels: 1
      }
    })
    |> child(:output, Membrane.PortAudio.Sink)
  end

  def children(:step_5, opts) do
    peaks_per_second = Keyword.get(opts, :peaks_per_second, @default_peaks_per_second)

    peak_interval =
      round(1000 / peaks_per_second)

    child(:source, %PortAudio.Source{
      channels: 1,
      # sample_format: :s16le,
      sample_format: :f32le,
      sample_rate: 16000,
      portaudio_buffer_size: VAD.mono_samples(1000)
    })
    |> child(:peak_1, %Peakmeter{
      # We set this interval to ensure a reasonable pace of notifications
      interval: Membrane.Time.milliseconds(peak_interval)
    })
    |> child(:transcribe, %Relive.Audio.Whisper{serving: Relive.Whisper})
    |> child(:voice, %Relive.Audio.Kokoro{})
    |> child(:converter, %SWResample.Converter{
      input_stream_format: %Membrane.RawAudio{
        sample_format: :f32le,
        sample_rate: 24000,
        channels: 1
      },
      output_stream_format: %Membrane.RawAudio{
        sample_format: :f32le,
        sample_rate: 16000,
        channels: 1
      }
    })
    |> child(:output, Membrane.PortAudio.Sink)
  end

  @impl true
  def handle_child_notification(
        # Only grabbing one channel, simplifies things
        {:amplitudes, [amp | _]},
        element,
        _context,
        state
      ) do
    if is_number(amp) do
      Phoenix.PubSub.broadcast(Relive.PubSub, "amplitude", {:amp, element, amp})
    end

    {[], state}
  end

  def handle_child_notification(
        {:speaking, activity, probability},
        _element,
        _context,
        state
      ) do
    Phoenix.PubSub.broadcast(Relive.PubSub, "speaking", {:speaking, activity, probability})
    {[], state}
  end

  def handle_child_notification(
        # Only grabbing one channel, simplifies things
        {:transcript, text},
        _element,
        _context,
        state
      ) do
    Phoenix.PubSub.broadcast(Relive.PubSub, "assistant", {:transcript, text})

    {[], state}
  end

  def handle_child_notification(
        {:audiometer, :underrun},
        _element,
        _context,
        state
      ) do
    {[], state}
  end

  # We just ignore audiometer underruns, they are not terribly exciting
  def handle_child_notification(
        {:audiometer, _other},
        _element,
        _context,
        state
      ) do
    # Logger.info("Unhandled audiometer message for #{element}: #{inspect(other)}")
    {[], state}
  end

  def handle_child_notification({:assistant, chunks}, _element, _ctx, state) do
    Phoenix.PubSub.broadcast(Relive.PubSub, "assistant", {:chunks, chunks})
    {[], state}
  end

  def handle_child_notification(
        notification,
        _element,
        _context,
        state
      ) do
    IO.inspect(notification, label: "unhandled notification")
    {[], state}
  end
end
