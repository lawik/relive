defmodule Relive.Application do
  use Application
  alias Relive.Audio
  alias Nx.Serving

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Relive.PubSub},
      {Finch, name: Relive.Finch},
      Audio.Supervisor,
      {Serving, serving: Audio.Whisper.serving("base"), name: Relive.Whisper, batch_timeout: 200},
      {Serving, serving: Relive.LLM.serving(0.6), name: Relive.LLM, batch_timeout: 200},
      ReliveWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Relive.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Give whisper a job to ensure it gets fully loaded
    # Audio.Whisper.warmup()
    # Relive.LLM.warmup()
    result
  end

  @impl true
  def config_change(changed, _new, removed) do
    ReliveWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
