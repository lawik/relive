defmodule Relive do
  def go do
    pid = Process.whereis(Go)

    if pid do
      Process.exit(pid, :normal)
    end

    Relive.Audio.Pipeline.start_link(peaks_per_second: 1, name: Go)
  end
end
