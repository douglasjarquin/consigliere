defmodule Consigliere.MissionBootstrap do
  @moduledoc """
  Starts one Mission subtree for every Mission that still needs
  coordination. Idempotent under concurrent calls.
  """
  use GenServer

  import Ecto.Query

  alias Consigliere.Missions.Mission
  alias Consigliere.MissionDynamicSupervisor
  alias Consigliere.Repo

  @phases ~w(authorized active ready_for_review awaiting_integration_authorization integrating)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def boot do
    case Process.whereis(__MODULE__) do
      nil -> run()
      pid -> GenServer.call(pid, :boot, 30_000)
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{}, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    run()
    {:noreply, state}
  end

  @impl true
  def handle_call(:boot, _from, state) do
    {:reply, run(), state}
  end

  defp run do
    Repo.all(from(m in Mission, where: m.phase in ^@phases))
    |> Enum.each(&start_one/1)
  end

  defp start_one(mission) do
    case MissionDynamicSupervisor.start_mission(mission_id: mission.id) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, _} -> :ok
    end
  end
end
