defmodule Relive.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Relive.PubSub},
      {Finch, name: Relive.Finch},
      ReliveWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Relive.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ReliveWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
