defmodule Relive do
  def ensure_audio(variant \\ :default) do
    Relive.Audio.Supervisor.ensure_started(variant)
  end

  def subscribe_amplitude do
    Phoenix.PubSub.subscribe(Relive.PubSub, "amplitude")
  end

  def subscribe_speech do
    Phoenix.PubSub.subscribe(Relive.PubSub, "speaking")
  end

  def go do
    pid = Process.whereis(Go)

    if pid do
      Process.exit(pid, :normal)
    end

    Relive.Audio.Pipeline.start_link(peaks_per_second: 1, name: Go)
  end
end
