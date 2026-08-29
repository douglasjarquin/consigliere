defmodule Consigliere.MissionBootstrap do
  @moduledoc """
  Starts one Mission subtree for every Mission that still needs
  coordination. Idempotent under concurrent calls. Event-driven on
  authorization, with a periodic repair scan.
  """
  use GenServer

  import Ecto.Query

  alias Consigliere.DatabaseWriter
  alias Consigliere.DispatchOperations.DispatchOperation
  alias Consigliere.Incidents.Incident
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Missions.Mission
  alias Consigliere.MissionDynamicSupervisor
  alias Consigliere.Repo
  alias Consigliere.Txn

  @phases ~w(authorized active ready_for_review awaiting_integration_authorization integrating)
  @dispatch_terminal ~w(failed completed)
  @recoverable_attempts ~w(planned starting)
  @ensure_events ~w(mission.authorized mission.started mission.resumed)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def boot do
    case Process.whereis(__MODULE__) do
      nil -> run()
      pid -> GenServer.call(pid, :boot, 30_000)
    end
  end

  def ensure_mission(mission_id) do
    case Process.whereis(__MODULE__) do
      nil -> start_one_id(mission_id)
      pid -> GenServer.call(pid, {:ensure, mission_id}, 30_000)
    end
  end

  @impl true
  def init(opts) do
    env = Application.get_env(:consigliere_daemon, __MODULE__, [])
    interval = Keyword.get(opts, :poll_interval_ms, Keyword.get(env, :poll_interval_ms, 5_000))
    subscribe? = Keyword.get(opts, :subscribe, Keyword.get(env, :subscribe, true))
    if subscribe?, do: Consigliere.EventBus.subscribe()
    {:ok, %{poll_interval_ms: interval}, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    run()
    schedule_tick(state.poll_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:boot, _from, state) do
    {:reply, run(), state}
  end

  def handle_call({:ensure, mission_id}, _from, state) do
    {:reply, start_one_id(mission_id), state}
  end

  @impl true
  def handle_info({:domain_event, event}, state) do
    if event.type in @ensure_events, do: start_one_id(event.subject_id)
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    run()
    schedule_tick(state.poll_interval_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp run do
    mission_ids =
      Repo.all(from(m in Mission, where: m.phase in ^@phases, select: m.id))
      |> Kernel.++(
        Repo.all(
          from(o in DispatchOperation,
            where: o.status not in ^@dispatch_terminal,
            select: o.mission_id
          )
        )
      )
      |> Kernel.++(
        Repo.all(
          from(a in Attempt,
            where: a.status in ^@recoverable_attempts,
            select: a.mission_id
          )
        )
      )
      |> Enum.uniq()

    Enum.each(mission_ids, &start_one_id/1)
  end

  defp start_one_id(mission_id) do
    case Ecto.UUID.cast(mission_id) do
      {:ok, id} ->
        case Repo.get(Mission, id) do
          %Mission{phase: phase} = mission when phase in @phases -> start_one(mission)
          _ -> :ok
        end

      :error ->
        :ok
    end
  end

  defp start_one(mission) do
    case MissionDynamicSupervisor.start_mission(mission_id: mission.id) do
      {:ok, _} -> :ok
      {:error, reason} -> record_poison(mission, reason)
    end
  rescue
    exception -> record_poison(mission, Exception.message(exception))
  end

  defp record_poison(mission, reason) do
    _ =
      DatabaseWriter.transaction(fn ->
        Txn.insert!(
          Incident.changeset(%Incident{}, %{
            mission_id: mission.id,
            subject_type: "mission",
            subject_id: mission.id,
            severity: "error",
            reason: "mission bootstrap failed: #{inspect(reason)}"
          })
        )
      end)

    :ok
  end

  defp schedule_tick(:infinity), do: :ok

  defp schedule_tick(ms) when is_integer(ms) and ms > 0 do
    Process.send_after(self(), :tick, ms)
  end
end
