defmodule Relive do
  def go do
    Relive.Audio.Pipeline.start_link(peaks_per_second: 1)
  end
end
