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

  def switch_pipeline(variant \\ :default) do
    case DynamicSupervisor.which_children(__MODULE__) do
      [] ->
        opts = opts_from_variant(variant)
        DynamicSupervisor.start_child(__MODULE__, {Relive.Audio.Pipeline, opts})

      multiple ->
        Enum.each(multiple, fn {_, child, _, _} ->
          DynamicSupervisor.terminate_child(__MODULE__, child)
        end)

        opts = opts_from_variant(variant)
        DynamicSupervisor.start_child(__MODULE__, {Relive.Audio.Pipeline, opts})
    end
  end

  def opts_from_variant(variant) do
    [variant: variant]
  end
end
