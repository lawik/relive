defmodule ReliveWeb.BaseLive do
  use ReliveWeb, :live_view

  @impl true
  def mount(_, _, socket) do
    socket =
      socket
      |> assign(:last_amp, %{})
      |> assign(:status, :not_speaking)

    if connected?(socket) do
      Relive.ensure_audio()
      Relive.subscribe_amplitude()
      Relive.subscribe_speech()

      {:ok, socket}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_info({:amp, element, amp}, socket) do
    socket =
      socket
      |> assign(:last_amp, Map.put(socket.assigns.last_amp, element, amp))

    {:noreply, socket}
  end

  def handle_info({:speaking, event, _prob}, socket) do
    status =
      case event do
        :start ->
          :speaking

        :stop ->
          :not_speaking
      end

    socket =
      socket
      |> assign(:status, status)

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="speech">{@status}</div>
    <div :for={{element, amp} <- @last_amp}>
      <strong>{element}</strong> {Float.round(amp, 1)}
    </div>
    """
  end
end
