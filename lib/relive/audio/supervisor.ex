defmodule Relive.Audio.Supervisor do
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def ensure_started(variant \\ :default) do
    case DynamicSupervisor.which_children(__MODULE__) do
      [] ->
        opts = opts_from_variant(variant)
        DynamicSupervisor.start_child(__MODULE__, {Relive.Audio.Pipeline, opts})

      [{_, child, _, _}] ->
        {:ok, child}
    end
  end

  defp opts_from_variant(:default) do
    [
      peaks_per_second: 3
    ]
  end
end
