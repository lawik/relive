defmodule Relive.Audio.Buffer do
  use Membrane.Filter

  alias Membrane.RawAudio

  require Logger

  def_options(
    interval: [
      spec: Membrane.Time.t(),
      default: Membrane.Time.milliseconds(200),
      description: "How much buffer to build up."
    ]
  )

  def_input_pad(:input,
    availability: :always,
    flow_control: :auto,
    accepted_format: RawAudio
  )

  def_output_pad(:output,
    availability: :always,
    flow_control: :auto,
    accepted_format: RawAudio
  )

  @impl true
  def handle_init(_ctx, mod) do
    state = %{opts: mod, buffer: []}
    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[start_timer: {:forward, state.opts.interval}, demand: {:input, 1}], state}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {[demand: {:input, size}], state}
  end

  @impl true
  def handle_buffer(
        :input,
        %Membrane.Buffer{payload: data},
        _ctx,
        state
      ) do
    {[demand: {:input, 1}], %{state | buffer: [state.buffer, data]}}
  end

  @impl true
  def handle_tick(:forward, _ctx, state) do
    buffer = %Membrane.Buffer{payload: IO.iodata_to_binary(state.buffer)}
    {[buffer: {:output, buffer}], %{state | buffer: []}}
  end
end
