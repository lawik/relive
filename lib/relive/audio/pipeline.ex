defmodule Relive.Audio.Pipeline do
  use Membrane.Pipeline
  alias Relive.Audio.VAD
  alias Relive.Audio.Timestamper

  @target_sample_rate 16000
  @bitdepth 32
  @byte_per_sample @bitdepth / 8
  @byte_per_second @target_sample_rate * @byte_per_sample

  def start_link(opts) do
    Membrane.Pipeline.start_link(__MODULE__, opts)
  end

  @default_peaks_per_second 60

  @impl true
  def handle_init(_ctx, opts) do
    peaks_per_second = Keyword.get(opts, :peaks_per_second, @default_peaks_per_second)
    # Setup the flow of the data
    # Stream from file
    spec =
      child(:source, %Membrane.PortAudio.Source{
        channels: 1,
        # sample_format: :s16le,
        sample_format: :f32le,
        sample_rate: 16000,
        portaudio_buffer_size: 1600
      })
      |> child(:timestamper, %Timestamper{bytes_per_second: @byte_per_second})
      |> child(:levels, Membrane.Audiometer.Peakmeter)
      |> child(:vad, VAD)
      |> child(:converter, %Membrane.FFmpeg.SWResample.Converter{
        output_stream_format: %Membrane.RawAudio{
          sample_format: :s32le,
          sample_rate: 44_100,
          channels: 2
        }
      })
      # Stream data into PortAudio to play it on speakers.
      # |> child(:output, Membrane.PortAudio.Sink)
      # Throw it away
      |> child(:output, Membrane.Fake.Sink.Buffers)

    # |> child(:output, %Membrane.PortAudio.Sink{})
    # |> child(:file, %Membrane.File.Sink{location: "/data/local.raw"})

    peak_interval = round(1000 / @target_fps)
    {[spec: spec], %{amps: [], clock_started?: false, peak_interval: peak_interval}}
  end

  @impl true
  def handle_child_notification(
        # Only grabbing one channel, simplifies things
        {:amplitudes, [amp | _]},
        _element,
        _context,
        state
      ) do
    actions =
      case state do
        %{clock_started?: false} ->
          # Let membrane figure out timing
          [start_timer: {:frame, Membrane.Time.milliseconds(state.peak_interval)}]

        _ ->
          []
      end

    {actions, %{state | amps: [amp | state.amps], clock_started?: true}}
  end

  def handle_child_notification(
        {:speaking, activity, probability},
        _element,
        _context,
        state
      ) do
    IO.inspect(activity)
    Phoenix.PubSub.broadcast(Relive.PubSub, "speaking", {:speaking, activity, probability})
    {[], state}
  end

  # We just ignore audiometer underruns, they are not terribly exciting
  def handle_child_notification(
        {:audiometer, :underrun},
        _element,
        _context,
        state
      ) do
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

  @impl true
  def handle_tick(:frame, _ctx, state) do
    if state.amps != [] do
      avg = Enum.sum(state.amps) / Enum.count(state.amps)
      Phoenix.PubSub.broadcast(Relive.PubSub, "amplitude", {:amp, avg})
    end

    {[], %{state | amps: []}}
  end
end
