defmodule Consigliere.MissionDynamicSupervisor do
  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # The one sanctioned way to start a mission subtree. Callers must never
  # start Consigliere.MissionCoordinator directly under this supervisor --
  # doing so would bypass MissionSupervisor's per-mission restart-intensity
  # isolation and silently reintroduce the blast-radius bug this module's
  # topology exists to prevent (this exact regression happened twice before
  # this function existed).
  def start_mission(opts) do
    mission_id = Keyword.fetch!(opts, :mission_id)

    case Registry.lookup(Consigliere.Registry, {:mission_supervisor, mission_id}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(__MODULE__, {Consigliere.MissionSupervisor, opts}) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          {:error, _} = err ->
            case Registry.lookup(Consigliere.Registry, {:mission_supervisor, mission_id}) do
              [{pid, _}] -> {:ok, pid}
              [] -> err
            end
        end
    end
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
