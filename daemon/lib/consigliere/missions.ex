defmodule Consigliere.Missions do
  @moduledoc false

  alias Consigliere.Missions.Transitions

  defdelegate create(attrs, actor), to: Transitions
  defdelegate submit_for_authorization(mission_id, actor), to: Transitions

  def request_changes(mission_id, actor, reason \\ nil),
    do: Transitions.request_changes(mission_id, actor, reason)

  defdelegate start(mission_id, actor, opts), to: Transitions
  defdelegate mark_ready_for_review(mission_id, actor), to: Transitions
  defdelegate return_to_active(mission_id, actor, reason), to: Transitions
  defdelegate await_integration_authorization(mission_id, actor, attrs), to: Transitions
  defdelegate grant_integration_authorization(mission_id, actor, attrs), to: Transitions
  defdelegate complete_integration(mission_id, actor, attrs), to: Transitions
  defdelegate detect_integration_race(mission_id, actor, reason), to: Transitions

  def fail(mission_id, actor, attrs) do
    with {:ok, mission} <- Transitions.fail(mission_id, actor, attrs) do
      terminate_runners(mission.id)
      {:ok, mission}
    end
  end

  def cancel(mission_id, actor, reason) do
    with {:ok, mission} <- Transitions.cancel(mission_id, actor, reason) do
      terminate_runners(mission.id)
      {:ok, mission}
    end
  end

  def supersede(mission_id, actor, replacement_attrs) do
    with {:ok, result} <- Transitions.supersede(mission_id, actor, replacement_attrs) do
      terminate_runners(mission_id)
      {:ok, result}
    end
  end

  defdelegate resume_after_decision(mission_id, actor, decision_id), to: Transitions
  defdelegate required_gate_types(mission), to: Transitions

  def resume(mission_id, actor) do
    with {:ok, mission} <- Transitions.resume(mission_id, actor) do
      _ = Consigliere.MissionBootstrap.ensure_mission(mission.id)
      {:ok, mission}
    end
  end

  def pause(mission_id, actor, reason \\ "boss pause") do
    with {:ok, mission} <- Transitions.pause(mission_id, actor, reason) do
      Consigliere.Pause.settle(mission.id)
    end
  end

  def grant_work_authorization(mission_id, actor, attrs \\ %{}) do
    attrs = Map.put_new_lazy(attrs, :base_sha, fn -> peek_base_sha(mission_id) end)

    with {:ok, mission} <- Transitions.grant_work_authorization(mission_id, actor, attrs) do
      maybe_provision(mission)
      _ = Consigliere.MissionBootstrap.ensure_mission(mission.id)
      {:ok, mission}
    end
  end

  def grant_work_authorization_command(mission_id, actor, attrs \\ %{}) do
    Transitions.grant_work_authorization(mission_id, actor, attrs)
  end

  defp peek_base_sha(mission_id) do
    case Consigliere.Repo.get(Consigliere.Missions.Mission, mission_id) do
      %{project_id: project_id} when is_binary(project_id) ->
        case Consigliere.Repo.get(Consigliere.Projects.Project, project_id) do
          %Consigliere.Projects.Project{} = project ->
            if File.exists?(Path.join(project.trusted_mirror_path, "HEAD")) do
              Consigliere.Projects.head_sha(project)
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp maybe_provision(mission) do
    case mission.project_id &&
           Consigliere.Repo.get(Consigliere.Projects.Project, mission.project_id) do
      %Consigliere.Projects.Project{} = project ->
        if File.exists?(Path.join(project.trusted_mirror_path, "HEAD")) do
          dest = Path.join(Consigliere.Home.workspaces_dir(), mission.id)
          sha = mission.base_sha || Consigliere.Projects.head_sha(project)

          unless File.dir?(dest) do
            Consigliere.Projects.provision_workspace(project, mission.id, sha)
          end
        end

        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp terminate_runners(mission_id) do
    import Ecto.Query

    Consigliere.Repo.all(
      from(a in Consigliere.Attempts.Attempt, where: a.mission_id == ^mission_id, select: a.id)
    )
    |> Enum.each(fn attempt_id ->
      case Registry.lookup(Consigliere.Registry, {:runner, attempt_id}) do
        [{pid, _}] -> Consigliere.RunnerProcess.cancel(pid)
        _ -> :ok
      end
    end)
  end
end
