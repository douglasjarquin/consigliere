defmodule Consigliere.Dispatch do
  @moduledoc """
  Authoritative runnable-Mission to live-runner transition.
  Registry lookup never creates work. planned/starting Attempts resume
  from durable dispatch state instead of occupying the slot forever.
  """

  alias Consigliere.Actor
  alias Consigliere.AttemptStates
  alias Consigliere.Attempts
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Capabilities
  alias Consigliere.DispatchOperations
  alias Consigliere.GlobalScheduler
  alias Consigliere.Home
  alias Consigliere.Missions
  alias Consigliere.RunnerDynamicSupervisor
  alias Consigliere.RunnerProcess

  @max_spawn_attempts 3

  def maybe_schedule(state, mission, true, []) when mission.phase == "authorized" do
    case GlobalScheduler.request_slot(mission.id) do
      {:ok, grant} -> start(state, mission, grant)
      {:error, :busy} -> %{state | view: Map.put(state.view, :reason, :capacity)}
    end
  end

  def maybe_schedule(state, mission, true, occupying) when occupying != [] do
    recover(state, mission, occupying)
  end

  def maybe_schedule(state, _mission, _runnable, _occupying), do: state

  defp start(state, mission, grant) do
    path = Path.join(Home.workspaces_dir(), to_string(mission.id))

    case Missions.start(mission.id, Actor.system(), %{workspace_path: path}) do
      {:ok, %{attempt: attempt}} ->
        {:ok, _} =
          DispatchOperations.ensure(attempt, %{status: "pending", slot_state: slot_name(grant)})

        continue(state, mission, grant, attempt)

      {:error, _} ->
        GlobalScheduler.release_slot(mission.id)
        %{state | slot: nil}
    end
  end

  defp recover(state, mission, occupying) do
    if is_pid(state.runner_pid) do
      state
    else
      occupying
      |> Enum.filter(&AttemptStates.recoverable?(&1.status))
      |> List.first()
      |> case do
        nil -> state
        attempt -> resume(state, mission, attempt)
      end
    end
  end

  defp resume(state, mission, %Attempt{status: "planned"} = attempt) do
    {:ok, _} = DispatchOperations.ensure(attempt, %{status: "pending", slot_state: "held"})
    grant = slot_or_request(mission.id)
    continue(state, mission, grant, attempt)
  end

  defp resume(state, mission, %Attempt{status: "starting"} = attempt) do
    case Registry.lookup(Consigliere.Registry, {:runner, attempt.id}) do
      [{pid, _}] ->
        attach(state, attempt, pid)

      [] ->
        if File.exists?(inventory_path(attempt.id)) do
          state
        else
          retry_child(state, mission, attempt)
        end
    end
  end

  defp resume(state, _mission, _attempt), do: state

  defp continue(state, mission, grant, %Attempt{status: "planned"} = attempt) do
    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())
    mark_spawn_requested(attempt)
    launch(state, mission, grant, attempt)
  end

  defp continue(state, mission, grant, attempt), do: launch(state, mission, grant, attempt)

  defp retry_child(state, mission, attempt) do
    op = DispatchOperations.get_by_attempt(attempt.id)
    attempts = (op && op.spawn_attempts) || 0

    if attempts >= @max_spawn_attempts do
      _ = Attempts.mark_spawn_failed(attempt.id, Actor.system(), "child start retries exhausted")
      if op, do: DispatchOperations.update(op, %{status: "failed", child_start_state: "failed"})
      GlobalScheduler.release_slot(mission.id)
      %{state | slot: nil}
    else
      if op, do: DispatchOperations.update(op, %{spawn_attempts: attempts + 1})
      launch(state, mission, slot_or_request(mission.id), attempt)
    end
  end

  defp launch(state, mission, grant, attempt) do
    {:ok, capability} = Capabilities.mint(attempt)
    runtime = Path.join(Home.runtime_attempts_dir(), attempt.id)
    File.mkdir_p!(runtime)
    workspace = Path.join(Home.workspaces_dir(), to_string(mission.id))

    spec =
      {RunnerProcess,
       [
         attempt_id: attempt.id,
         mission_id: mission.id,
         fencing_token: attempt.fencing_token,
         heartbeat_file: Path.join(runtime, "heartbeat"),
         workspace_path: workspace,
         capability: capability
       ]}

    case DynamicSupervisor.start_child(RunnerDynamicSupervisor, spec) do
      {:ok, runner_pid} ->
        mark_child_started(attempt)
        attach(state, attempt, runner_pid, grant)

      {:error, {:already_started, runner_pid}} ->
        attach(state, attempt, runner_pid, grant)

      {:error, reason} ->
        _ = Attempts.mark_spawn_failed(attempt.id, Actor.system(), inspect(reason))
        GlobalScheduler.release_slot(mission.id)
        %{state | slot: nil, attempt_id: attempt.id, runner_pid: nil}
    end
  end

  defp attach(state, attempt, runner_pid, grant \\ :held) do
    %{
      state
      | slot: grant,
        attempt_id: attempt.id,
        runner_pid: runner_pid,
        runner_ref: Process.monitor(runner_pid)
    }
  end

  defp slot_or_request(mission_id) do
    case GlobalScheduler.request_slot(mission_id) do
      {:ok, grant} -> grant
      {:error, :busy} -> :held
    end
  end

  defp slot_name(:granted), do: "granted"
  defp slot_name(_), do: "held"

  defp inventory_path(attempt_id),
    do: Path.join(Home.runtime_attempts_dir(), "#{attempt_id}/manifest.json")

  defp mark_spawn_requested(attempt) do
    case DispatchOperations.get_by_attempt(attempt.id) do
      nil -> :ok
      op -> DispatchOperations.update(op, %{status: "spawn_requested"})
    end
  end

  defp mark_child_started(attempt) do
    case DispatchOperations.get_by_attempt(attempt.id) do
      nil ->
        :ok

      op ->
        DispatchOperations.update(op, %{
          status: "child_started",
          child_start_state: "started",
          spawn_attempts: op.spawn_attempts + 1
        })
    end
  end
end
