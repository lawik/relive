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

    # Throw it away

    # |> child(:output, Membrane.Fake.Sink.Buffers)
    # |> child(:converter, %SWResample.Converter{
    #   output_stream_format: %Membrane.RawAudio{
    #     sample_format: :s32le,
    #     sample_rate: 44_100,
    #     channels: 2
    #   }
    # })

    # |> child(:output, %Membrane.PortAudio.Sink{})
    # |> child(:file, %Membrane.File.Sink{location: "/data/local.raw"})

    {[spec: spec], %{amps: %{peak_1: [], peak_2: []}, clock_started?: false}}
  end

  @chunk_ms 200
  defp children(:default, opts) do
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
    |> child(:assistant, %Relive.LLM{serving: Relive.LLM})
    |> child(:voice, Relive.Audio.Kokoro)
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
    # Stream data into PortAudio to play it on speakers.
    # |> child(:output, %Membrane.File.Sink{location: "file.pcm"})

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

  def handle_child_notification(
        _notification,
        _element,
        _context,
        state
      ) do
    # IO.inspect(notification, label: "unhandled notification")
    {[], state}
  end
end
