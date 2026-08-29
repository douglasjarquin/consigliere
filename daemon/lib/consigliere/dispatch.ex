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
  alias Consigliere.Runtime.Inventory

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
          DispatchOperations.ensure(attempt, %{
            status: "workspace_ready",
            slot_state: slot_name(grant)
          })

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
    with {:ok, operation} <-
           DispatchOperations.ensure(attempt, %{status: "pending", slot_state: "pending"}),
         :ok <- prepare_workspace(mission, attempt),
         {:ok, grant} <- request_slot(mission.id),
         {:ok, _mission} <-
           Missions.activate_dispatch(
             mission.id,
             Actor.system(),
             attempt.id,
             attempt.workspace_id
           ),
         {:ok, _} <-
           DispatchOperations.update(operation, %{
             status: "workspace_ready",
             slot_state: slot_name(grant)
           }) do
      continue(state, mission, grant, attempt)
    else
      {:error, :busy} -> %{state | view: Map.put(state.view, :reason, :capacity)}
      {:error, reason} -> fail_planned_dispatch(state, mission, attempt, reason)
    end
  end

  defp resume(state, _mission, %Attempt{status: "starting"} = attempt) do
    case Registry.lookup(Consigliere.Registry, {:runner, attempt.id}) do
      [{pid, _}] ->
        attach(state, attempt, pid)

      [] ->
        mark_unknown_dispatch(state, attempt, inventory_state(attempt.id))
    end
  end

  defp resume(state, _mission, _attempt), do: state

  defp continue(state, mission, grant, %Attempt{status: "planned"} = attempt) do
    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())
    mark_spawn_requested(attempt)
    launch(state, mission, grant, attempt)
  end

  defp continue(state, mission, grant, attempt), do: launch(state, mission, grant, attempt)

  defp launch(state, mission, grant, attempt) do
    project = mission.project_id && Repo.get(Project, mission.project_id)
    fallback_workspace = Path.join(Home.workspaces_dir(), to_string(mission.id))

    case resolve_launch_identity(mission, attempt, project, fallback_workspace) do
      {:error, reason} ->
        _ =
          Attempts.mark_spawn_failed(attempt.id, Actor.system(), "workspace identity: #{reason}")

        mark_dispatch_failed(attempt, reason)

        GlobalScheduler.release_slot(mission.id)
        %{state | slot: nil, attempt_id: attempt.id, runner_pid: nil}

      {:ok,
       %{
         mission: launch_mission,
         attempt: launch_attempt,
         workspace: workspace,
         workspace_generation: workspace_generation
       }} ->
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

            mark_dispatch_failed(launch_attempt, :context_pack_too_large)

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
              workspace_generation,
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
          :ok ->
            {:ok,
             %{
               mission: mission,
               attempt: attempt,
               workspace: workspace.path,
               workspace_generation: workspace.lease_id
             }}

          {:error, reason} ->
            {:error, inspect(reason)}
        end

      true ->
        {:ok,
         %{
           mission: mission,
           attempt: attempt,
           workspace: workspace.path || fallback_workspace,
           workspace_generation: workspace.lease_id
         }}
    end
  end

  defp trusted_project?(%Project{} = project) do
    Projects.trusted_identity?(project)
  end

  defp trusted_project?(_), do: false

  defp start_runner(state, mission, grant, attempt, workspace, workspace_generation, pack, policy) do
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
         workspace_generation: workspace_generation,
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
        mark_dispatch_failed(attempt, reason)
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

  defp request_slot(mission_id) do
    case GlobalScheduler.request_slot(mission_id) do
      {:ok, grant} -> {:ok, grant}
      {:error, :busy} -> {:error, :busy}
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

  defp prepare_workspace(mission, attempt) do
    workspace = Repo.get(Workspace, attempt.workspace_id)
    project = mission.project_id && Repo.get(Project, mission.project_id)

    cond do
      not match?(%Workspace{}, workspace) ->
        {:error, :workspace_not_found}

      trusted_project?(project) and File.dir?(workspace.path) ->
        case Projects.verify_workspace_identity(project, mission, workspace) do
          :ok -> mark_workspace_ready(attempt)
          {:error, reason} -> {:error, reason}
        end

      trusted_project?(project) ->
        sha = workspace.parent_checkpoint_sha || workspace.base_sha || mission.base_sha

        if is_binary(sha) and sha != "" do
          try do
            _ = Projects.provision_workspace(project, Path.basename(workspace.path), sha)

            case Projects.verify_workspace_identity(project, mission, workspace) do
              :ok -> mark_workspace_ready(attempt)
              {:error, reason} -> {:error, reason}
            end
          rescue
            exception -> {:error, Exception.message(exception)}
          end
        else
          {:error, :workspace_base_missing}
        end

      true ->
        mark_workspace_ready(attempt)
    end
  end

  defp mark_workspace_ready(attempt) do
    case DispatchOperations.get_by_attempt(attempt.id) do
      nil -> :ok
      operation -> DispatchOperations.update(operation, %{status: "workspace_ready"})
    end

    :ok
  end

  defp fail_planned_dispatch(state, mission, attempt, reason) do
    _ =
      Attempts.mark_spawn_failed(
        attempt.id,
        Actor.system(),
        "workspace preparation: #{inspect(reason)}"
      )

    mark_dispatch_failed(attempt, reason)
    GlobalScheduler.release_slot(mission.id)

    %{
      state
      | slot: nil,
        attempt_id: attempt.id,
        runner_pid: nil,
        view: Map.put(state.view, :reason, :dispatch_failed)
    }
  end

  defp mark_dispatch_failed(attempt, reason) do
    case DispatchOperations.get_by_attempt(attempt.id) do
      nil ->
        :ok

      operation ->
        DispatchOperations.update(operation, %{
          status: "failed",
          child_start_state: "failed",
          last_error: bounded_error(reason)
        })
    end
  end

  defp bounded_error(reason), do: reason |> inspect() |> String.slice(0, 512)

  defp mark_unknown_dispatch(state, attempt, inventory) do
    case DispatchOperations.get_by_attempt(attempt.id) do
      nil ->
        :ok

      operation ->
        _ =
          DispatchOperations.update(operation, %{
            status: "unknown",
            child_start_state: "unknown",
            slot_state: "unknown",
            last_error: "runner identity reconciliation required: #{inventory}"
          })
    end

    %{
      state
      | attempt_id: attempt.id,
        runner_pid: nil,
        view: Map.put(state.view, :reason, :unknown)
    }
  end

  defp inventory_state(attempt_id) do
    case Inventory.verify(inventory_path(attempt_id), Home.dir()) do
      :missing -> "manifest_missing"
      {:valid_live, _manifest, _attempt} -> "manifest_live"
      {:valid_terminal, _manifest, _attempt} -> "manifest_terminal"
      :identity_mismatch -> "manifest_identity_mismatch"
      :stale_generation -> "manifest_stale_generation"
      :unsafe_pgid -> "manifest_unsafe_pgid"
      :corrupt -> "manifest_corrupt"
      other -> inspect(other)
    end
  rescue
    _ -> "manifest_unavailable"
  end
end
