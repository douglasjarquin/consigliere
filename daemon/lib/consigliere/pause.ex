defmodule Consigliere.Pause do
  @moduledoc """
  Immediate controlled pause: revoke authority, stop live runners, import
  a checkpoint when one exists, and settle paused only after verified death.
  """

  import Ecto.Query

  alias Consigliere.Actor
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Checkpoints
  alias Consigliere.DatabaseWriter
  alias Consigliere.MissionBlockers.MissionBlocker
  alias Consigliere.Missions.Mission
  alias Consigliere.Projects.Project
  alias Consigliere.Repo
  alias Consigliere.Termination
  alias Consigliere.Txn
  alias Consigliere.Workspaces
  alias Consigliere.Workspaces.Workspace

  def settle(mission_id) do
    mission = Repo.get!(Mission, mission_id)

    if mission.phase == "paused" do
      {:ok, %{mission: mission, status: :paused, checkpoint_sha: mission.current_checkpoint_sha}}
    else
      outcomes = Enum.map(live_attempts(mission_id), &stop_one/1)
      finalize(mission_id, outcomes)
    end
  end

  defp stop_one(attempt) do
    Termination.cancel_runner(attempt.id)
    death = Termination.verify_death(attempt)

    if death == :dead_verified do
      case maybe_import(attempt) do
        :ok -> :ok
        {:error, reason} -> {:error, {:checkpoint_import_failed, reason}}
      end
    else
      maybe_quarantine(attempt)
      {:error, :death_unverified}
    end
  end

  defp maybe_import(attempt) do
    sha = attempt.reported_checkpoint_sha
    workspace = attempt.workspace_id && Repo.get(Workspace, attempt.workspace_id)
    mission = Repo.get!(Mission, attempt.mission_id)
    project = mission.project_id && Repo.get(Project, mission.project_id)

    if importable?(sha, workspace, project) do
      case Checkpoints.import_after_death(
             attempt.id,
             process_group: :dead_verified,
             workspace_path: workspace.path,
             mirror_path: project.trusted_mirror_path,
             sha: sha,
             base_sha: workspace.base_sha || mission.base_sha
           ) do
        {:ok, _result} ->
          :ok

        {:error, reason} ->
          record_checkpoint_import_failure(attempt, reason)
          {:error, reason}
      end
    else
      :ok
    end
  end

  defp importable?(sha, %Workspace{path: path}, %Project{trusted_mirror_path: mirror})
       when is_binary(sha) and sha != "" and is_binary(path) and path != "" and
              is_binary(mirror) and mirror != "",
       do: true

  defp importable?(_, _, _), do: false

  defp maybe_quarantine(%Attempt{workspace_id: id}) when is_binary(id) do
    _ = Workspaces.quarantine(id, Actor.system(), "pause death unverified")
  end

  defp maybe_quarantine(_), do: :ok

  defp finalize(mission_id, outcomes) do
    leftover = Enum.filter(live_attempts(mission_id), &Termination.process_alive?/1)

    DatabaseWriter.transaction(fn ->
      mission = Repo.get!(Mission, mission_id)

      if leftover == [] and Enum.all?(outcomes, &(&1 == :ok)) do
        close_blockers!(mission, "pausing")
        open_paused!(mission)
        mission = Txn.update!(Mission.changeset(mission, %{phase: "paused"}))
        Txn.append_event!("mission.paused", "mission", mission.id)

        {:ok,
         %{mission: mission, status: :paused, checkpoint_sha: mission.current_checkpoint_sha}}
      else
        {:ok, %{mission: mission, status: :pausing, checkpoint_sha: nil}}
      end
    end)
    |> case do
      {:ok, result} -> result
      other -> other
    end
  end

  defp record_checkpoint_import_failure(attempt, reason) do
    detail = "pause checkpoint import failed: #{inspect(reason) |> String.slice(0, 256)}"

    DatabaseWriter.transaction(fn ->
      exists? =
        Repo.exists?(
          from(i in Consigliere.Incidents.Incident,
            where:
              i.mission_id == ^attempt.mission_id and i.subject_id == ^attempt.id and
                i.reason == ^detail
          )
        )

      unless exists? do
        Txn.insert!(
          Consigliere.Incidents.Incident.changeset(%Consigliere.Incidents.Incident{}, %{
            mission_id: attempt.mission_id,
            subject_type: "attempt",
            subject_id: attempt.id,
            severity: "error",
            reason: detail
          })
        )
      end
    end)

    :ok
  end

  defp live_attempts(mission_id) do
    Repo.all(
      from(a in Attempt,
        where:
          a.mission_id == ^mission_id and
            a.status in ["planned", "starting", "running", "checkpoint_requested", "terminating"]
      )
    )
  end

  defp close_blockers!(mission, kind) do
    from(b in MissionBlocker,
      where: b.mission_id == ^mission.id and b.kind == ^kind and b.status == "open"
    )
    |> Repo.all()
    |> Enum.each(fn b ->
      Txn.update!(
        MissionBlocker.changeset(b, %{
          status: "closed",
          closed_reason: "pause settled",
          closed_at: Txn.now()
        })
      )
    end)
  end

  defp open_paused!(mission) do
    exists =
      Repo.one(
        from(b in MissionBlocker,
          where: b.mission_id == ^mission.id and b.kind == "paused" and b.status == "open",
          limit: 1
        )
      )

    if is_nil(exists) do
      Txn.insert!(
        MissionBlocker.changeset(%MissionBlocker{}, %{
          mission_id: mission.id,
          kind: "paused",
          reason: "boss pause",
          status: "open"
        })
      )
    end
  end
end
