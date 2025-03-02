defmodule Relive.Audio.Buffer do
  use Membrane.Filter

  alias Membrane.RawAudio

  require Logger

  def_options(
    duration_ms: [
      spec: integer(),
      default: 1000,
      description: "How much buffer to build up in milliseconds. Default: 1000"
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
    accepted_format: RawAudio
  )

  @impl true
  def handle_init(_ctx, mod) do
    state = %{opts: mod, buffer: [], timer: nil}
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
        %{pads: %{input: %{stream_format: %{sample_format: f, sample_rate: sr, channels: ch}}}} =
          _ctx,
        state
      ) do
    bytes_per_sample =
      case f do
        :f32le -> 32 / 8
      end

    byte_limit = sr / 1000 * state.opts.duration_ms * bytes_per_sample
    buffer = [state.buffer, data]

    state =
      if state.timer do
        state
      else
        timer = Process.send_after(self(), :timeout, state.opts.duration_ms)
        %{state | timer: timer}
      end

    if IO.iodata_length(buffer) < byte_limit do
      {[demand: {:input, 1}], %{state | buffer: buffer}}
    else
      IO.puts("Buffer full")
      out_buffer = %Membrane.Buffer{payload: IO.iodata_to_binary(buffer)}

      state =
        if state.timer do
          Process.cancel_timer(state.timer)
          %{state | timer: nil}
        else
          state
        end

      {[
         demand: {:input, 1},
         buffer: {:output, out_buffer}
       ], %{state | buffer: []}}
    end
  end

  @impl true
  def handle_info(:timeout, _ctx, state) do
    IO.puts("Buffer expired")

    if state.buffer != [] do
      out_buffer = %Membrane.Buffer{payload: IO.iodata_to_binary(state.buffer)}

      {[buffer: {:output, out_buffer}], %{state | buffer: [], timer: nil}}
    else
      {[], state}
    end
  end
end
