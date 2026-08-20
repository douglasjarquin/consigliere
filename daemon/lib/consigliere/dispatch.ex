defmodule Consigliere.Dispatch do
  @moduledoc """
  Authoritative runnable-Mission to live-runner transition.
  Registry lookup never creates work.
  """

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Capabilities
  alias Consigliere.GlobalScheduler
  alias Consigliere.Home
  alias Consigliere.Missions
  alias Consigliere.RunnerDynamicSupervisor
  alias Consigliere.RunnerProcess

  def maybe_schedule(state, mission, true, []) when mission.phase == "authorized" do
    case GlobalScheduler.request_slot(mission.id) do
      {:ok, grant} -> start(state, mission, grant)
      {:error, :busy} -> %{state | view: Map.put(state.view, :reason, :capacity)}
    end
  end

  def maybe_schedule(state, _mission, _runnable, _occupying), do: state

  defp start(state, mission, grant) do
    path = Path.join(Home.workspaces_dir(), to_string(mission.id))

    case Missions.start(mission.id, Actor.system(), %{workspace_path: path}) do
      {:ok, %{attempt: attempt}} ->
        launch(state, mission, grant, attempt)

      {:error, _} ->
        GlobalScheduler.release_slot(mission.id)
        %{state | slot: nil}
    end
  end

  defp launch(state, mission, grant, attempt) do
    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())
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
        %{
          state
          | slot: grant,
            attempt_id: attempt.id,
            runner_pid: runner_pid,
            runner_ref: Process.monitor(runner_pid)
        }

      {:error, reason} ->
        _ = Attempts.mark_spawn_failed(attempt.id, Actor.system(), inspect(reason))
        GlobalScheduler.release_slot(mission.id)
        %{state | slot: nil, attempt_id: attempt.id, runner_pid: nil}
    end
  end
end
