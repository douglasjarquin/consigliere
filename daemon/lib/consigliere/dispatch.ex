defmodule Consigliere.Dispatch do
  @moduledoc """
  Authoritative runnable-Mission to live-runner transition.
  Registry lookup never creates work. planned/starting Attempts resume
  from durable dispatch state instead of occupying the slot forever.
  """

  alias Consigliere.Actor
  alias Consigliere.Adapters
  alias Consigliere.AttemptStates
  alias Consigliere.Attempts
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Capabilities
  alias Consigliere.DatabaseWriter
  alias Consigliere.DispatchOperations
  alias Consigliere.GlobalScheduler
  alias Consigliere.Harness.Codex
  alias Consigliere.Harness.ContextPack
  alias Consigliere.Home
  alias Consigliere.Missions
  alias Consigliere.Projects
  alias Consigliere.Projects.Project
  alias Consigliere.Repo
  alias Consigliere.RunnerDynamicSupervisor
  alias Consigliere.RunnerProcess
  alias Consigliere.Txn
  alias Consigliere.Workspaces.Workspace

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
    path = workspace_dest(mission)
    maybe_materialize(mission, path)

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
    project = mission.project_id && Repo.get(Project, mission.project_id)
    fallback_workspace = Path.join(Home.workspaces_dir(), to_string(mission.id))

    case resolve_launch_identity(mission, attempt, project, fallback_workspace) do
      {:error, reason} ->
        _ =
          Attempts.mark_spawn_failed(attempt.id, Actor.system(), "workspace identity: #{reason}")

        GlobalScheduler.release_slot(mission.id)
        %{state | slot: nil, attempt_id: attempt.id, runner_pid: nil}

      {:ok, %{mission: launch_mission, attempt: launch_attempt, workspace: workspace}} ->
        policy = Codex.policy(project)

        extras = %{
          workspace_path: workspace,
          base_sha: launch_mission.base_sha,
          role: launch_attempt.role
        }

        case ContextPack.compose(launch_mission, extras) do
          {:error, :too_large} ->
            _ =
              Attempts.mark_spawn_failed(
                launch_attempt.id,
                Actor.system(),
                "context pack too large"
              )

            GlobalScheduler.release_slot(launch_mission.id)
            %{state | slot: nil, attempt_id: launch_attempt.id, runner_pid: nil}

          {:ok, pack} ->
            {:ok, launch_attempt} = persist_pack(launch_attempt, pack, policy)

            start_runner(
              state,
              launch_mission,
              grant,
              launch_attempt,
              workspace,
              pack,
              policy
            )
        end
    end
  end

  defp resolve_launch_identity(mission, attempt, project, fallback_workspace) do
    workspace = attempt.workspace_id && Repo.get(Workspace, attempt.workspace_id)

    cond do
      not match?(%Workspace{}, workspace) ->
        {:error, "workspace_not_found"}

      trusted_project?(project) ->
        case Projects.verify_workspace_identity(project, mission, workspace) do
          :ok -> {:ok, %{mission: mission, attempt: attempt, workspace: workspace.path}}
          {:error, reason} -> {:error, inspect(reason)}
        end

      true ->
        {:ok,
         %{mission: mission, attempt: attempt, workspace: workspace.path || fallback_workspace}}
    end
  end

  defp trusted_project?(%Project{} = project) do
    Projects.trusted_identity?(project)
  end

  defp trusted_project?(_), do: false

  defp start_runner(state, mission, grant, attempt, workspace, pack, policy) do
    {:ok, capability} = Capabilities.mint(attempt)
    runtime = Path.join(Home.runtime_attempts_dir(), attempt.id)
    File.mkdir_p!(runtime)
    File.write!(Path.join(runtime, "context_pack.json"), pack.encoded)
    File.write!(Path.join(runtime, "dispatch.json"), JSON.encode!(policy))

    spec =
      {RunnerProcess,
       [
         attempt_id: attempt.id,
         mission_id: mission.id,
         fencing_token: attempt.fencing_token,
         heartbeat_file: Path.join(runtime, "heartbeat"),
         workspace_path: workspace,
         capability: capability,
         prompt: pack.encoded,
         policy: policy
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

  defp workspace_dest(mission) do
    base = Path.join(Home.workspaces_dir(), to_string(mission.id))

    if File.dir?(base) do
      Path.join(Home.workspaces_dir(), "#{mission.id}-#{System.unique_integer([:positive])}")
    else
      base
    end
  end

  defp maybe_materialize(mission, path) do
    sha = mission.current_checkpoint_sha || mission.base_sha
    project = mission.project_id && Repo.get(Project, mission.project_id)

    if match?(%Project{}, project) and is_binary(sha) and sha != "" and not File.dir?(path) do
      Consigliere.Projects.provision_workspace(project, Path.basename(path), sha)
    end
  rescue
    _ -> :ok
  end

  defp persist_pack(attempt, pack, _policy) do
    DatabaseWriter.transaction(fn ->
      Txn.update!(
        Attempt.changeset(attempt, %{
          input_context_hash: pack.hash,
          harness: Adapters.harness().capabilities()["harness_name"]
        })
      )
    end)
  end

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
