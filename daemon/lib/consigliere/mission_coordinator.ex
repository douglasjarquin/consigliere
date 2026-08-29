defmodule Consigliere.MissionCoordinator do
  @moduledoc """
  Disposable in-memory coordinator for one Mission.

  Authoritative state is always the projections. This process rehydrates
  on start, subscribes to EventBus, and periodically re-evaluates
  runnability (docs/architecture/runtime.md). It monitors a RunnerProcess
  if one exists; it never owns or links to it.

  Spike B still starts this with a non-UUID mission_id and an attempt_id
  that only exists in the runner Registry. That path skips DB rehydration.
  """
  use GenServer

  import Ecto.Query

  alias Consigliere.AttemptStates
  alias Consigliere.Dispatch
  alias Consigliere.DispatchOperations
  alias Consigliere.EventBus
  alias Consigliere.Missions.Mission
  alias Consigliere.MissionBlockers.MissionBlocker
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Repo

  def start_link(opts) do
    mission_id = Keyword.fetch!(opts, :mission_id)
    GenServer.start_link(__MODULE__, opts, name: via(mission_id))
  end

  def via(mission_id), do: {:via, Registry, {Consigliere.Registry, {:mission, mission_id}}}

  @call_timeout 30_000

  def runner_pid(pid), do: GenServer.call(pid, :runner_pid, @call_timeout)

  def snapshot(pid), do: GenServer.call(pid, :snapshot, @call_timeout)

  def evaluate(pid), do: GenServer.call(pid, :evaluate, @call_timeout)

  @impl true
  def init(opts) do
    mission_id = Keyword.fetch!(opts, :mission_id)
    attempt_id = Keyword.get(opts, :attempt_id)
    {runner_pid, runner_ref} = attach_runner(attempt_id)

    EventBus.subscribe()

    state = %{
      mission_id: mission_id,
      attempt_id: attempt_id,
      runner_pid: runner_pid,
      runner_ref: runner_ref,
      slot: nil,
      view: nil,
      scheduling: false,
      poll_interval_ms: poll_interval_ms()
    }

    {:ok, state, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    {:noreply, boot(state)}
  end

  @impl true
  def handle_call(:runner_pid, _from, state), do: {:reply, state.runner_pid, state}

  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_from(state), state}

  def handle_call(:evaluate, _from, state) do
    state = refresh_and_request_schedule(state)
    {:reply, snapshot_from(state), state}
  end

  @impl true
  def handle_info({:domain_event, event}, state) do
    if relevant?(event, state) do
      {:noreply, refresh_and_request_schedule(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{runner_ref: ref} = state) do
    {:noreply, refresh_and_request_schedule(%{state | runner_pid: :not_found, runner_ref: nil})}
  end

  def handle_info(:tick, state) do
    state = refresh_and_request_schedule(state)
    schedule_tick(state.poll_interval_ms)
    {:noreply, state}
  end

  def handle_info(:schedule, state) do
    {:noreply, perform_schedule(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp boot(state) do
    state = refresh_and_request_schedule(state)
    schedule_tick(state.poll_interval_ms)
    state
  end

  defp refresh_and_request_schedule(state) do
    state = refresh_view(state)
    request_schedule(state)
  end

  defp refresh_view(state) do
    case load_mission(state.mission_id) do
      nil ->
        %{state | view: %{runnable: false, reason: :no_projection}}

      mission ->
        blockers = open_blockers(mission.id)
        occupying = occupying_attempts(mission.id)
        dispatch = DispatchOperations.get_by_mission(mission.id)
        {runnable, reason} = runnability(mission, blockers, occupying, dispatch)

        %{
          state
          | view: %{
              phase: mission.phase,
              runnable: runnable,
              reason: reason,
              blockers: length(blockers)
            }
        }
    end
  end

  defp request_schedule(state) do
    if should_schedule?(state) and state.scheduling != true do
      send(self(), :schedule)
      %{state | scheduling: true}
    else
      state
    end
  end

  defp should_schedule?(state) do
    state.view[:runnable] == true and
      (state.view[:phase] == "authorized" or state.view[:reason] == :recover)
  end

  defp perform_schedule(state) do
    state = %{state | scheduling: false}

    case load_mission(state.mission_id) do
      nil ->
        state

      mission ->
        occupying = occupying_attempts(mission.id)
        dispatch = DispatchOperations.get_by_mission(mission.id)
        {runnable, reason} = runnability(mission, open_blockers(mission.id), occupying, dispatch)

        if reason in [:import, :validate] do
          _ = Consigliere.Progression.maybe_progress(mission.id)
        end

        Dispatch.maybe_schedule(state, mission, runnable, occupying)
    end
  end

  defp runnability(mission, blockers, occupying, dispatch) do
    recoverable = Enum.filter(occupying, &AttemptStates.recoverable?(&1.status))
    blocking = occupying -- recoverable

    cond do
      dispatch && dispatch.status == "unknown" ->
        {false, :unknown}

      dispatch && dispatch.status == "failed" ->
        {false, :dispatch_failed}

      dispatch && dispatch.status == "completed" ->
        {false, :dispatch_completed}

      dispatch && terminal_attempt?(dispatch.attempt_id) ->
        {false, :dispatch_terminal}

      mission.phase not in ["authorized", "active"] ->
        {false, :phase}

      blockers != [] ->
        {false, :blocked}

      blocking != [] ->
        {false, :occupying}

      recoverable != [] ->
        {true, :recover}

      mission.phase == "authorized" ->
        {true, :ready}

      true ->
        case Consigliere.Progression.next_action(mission) do
          :none -> {false, :waiting}
          action -> {false, action}
        end
    end
  end

  defp load_mission(mission_id) do
    case Ecto.UUID.cast(mission_id) do
      {:ok, id} -> Repo.get(Mission, id)
      :error -> nil
    end
  end

  defp open_blockers(mission_id) do
    Repo.all(from(b in MissionBlocker, where: b.mission_id == ^mission_id and b.status == "open"))
  end

  defp occupying_attempts(mission_id) do
    occupying = AttemptStates.occupying()

    Repo.all(
      from(a in Attempt,
        where: a.mission_id == ^mission_id and a.status in ^occupying
      )
    )
  end

  defp terminal_attempt?(attempt_id) do
    case Repo.get(Attempt, attempt_id) do
      %Attempt{status: status} -> AttemptStates.terminal?(status)
      _ -> false
    end
  end

  defp attach_runner(nil), do: {:not_found, nil}

  defp attach_runner(attempt_id) do
    case Registry.lookup(Consigliere.Registry, {:runner, attempt_id}) do
      [{pid, _}] ->
        ref = Process.monitor(pid)
        {pid, ref}

      [] ->
        {:not_found, nil}
    end
  end

  defp relevant?(event, state) do
    event.subject_id == state.mission_id or
      (is_binary(state.attempt_id) and event.subject_id == state.attempt_id) or
      payload_mission_id(event.payload) == state.mission_id
  end

  defp payload_mission_id(%{"mission_id" => id}), do: id
  defp payload_mission_id(%{mission_id: id}), do: id
  defp payload_mission_id(_), do: nil

  defp snapshot_from(state) do
    Map.merge(
      %{
        mission_id: state.mission_id,
        attempt_id: state.attempt_id,
        runner_pid: state.runner_pid,
        slot: state.slot
      },
      state.view || %{}
    )
  end

  defp schedule_tick(:infinity), do: :ok

  defp schedule_tick(ms) when is_integer(ms) and ms > 0 do
    Process.send_after(self(), :tick, ms)
  end

  defp poll_interval_ms do
    Application.get_env(:consigliere_daemon, __MODULE__, [])
    |> Keyword.get(:poll_interval_ms, 1_000)
  end
end
