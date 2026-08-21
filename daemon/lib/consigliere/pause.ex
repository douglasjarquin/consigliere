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
  alias Consigliere.ProcessGroup
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
      Enum.each(live_attempts(mission_id), &stop_one/1)
      finalize(mission_id)
    end
  end

  defp stop_one(attempt) do
    Termination.cancel_runner(attempt.id)
    death = verify_death(attempt)

    if death == :dead_verified do
      maybe_import(attempt)
    else
      maybe_quarantine(attempt)
    end

    death
  end

  defp verify_death(attempt) do
    cond do
      is_integer(attempt.pgid) and attempt.pgid > 1 ->
        ProcessGroup.terminate(attempt.pgid)

      process_alive?(attempt) ->
        :dead_unverified

      true ->
        :dead_verified
    end
  end

  defp maybe_import(attempt) do
    sha = attempt.reported_checkpoint_sha
    workspace = attempt.workspace_id && Repo.get(Workspace, attempt.workspace_id)
    mission = Repo.get!(Mission, attempt.mission_id)
    project = mission.project_id && Repo.get(Project, mission.project_id)

    if importable?(sha, workspace, project) do
      _ =
        Checkpoints.import_after_death(attempt.id,
          process_group: :dead_verified,
          workspace_path: workspace.path,
          mirror_path: project.trusted_mirror_path,
          sha: sha,
          base_sha: workspace.base_sha || mission.base_sha
        )
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

  defp finalize(mission_id) do
    leftover = Enum.filter(live_attempts(mission_id), &process_alive?/1)

    DatabaseWriter.transaction(fn ->
      mission = Repo.get!(Mission, mission_id)

      if leftover == [] do
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

  defp live_attempts(mission_id) do
    Repo.all(
      from(a in Attempt,
        where:
          a.mission_id == ^mission_id and
            a.status in ["planned", "starting", "running", "checkpoint_requested", "terminating"]
      )
    )
  end

  defp process_alive?(%Attempt{id: id, pgid: pgid}) do
    runner =
      case Registry.lookup(Consigliere.Registry, {:runner, id}) do
        [{pid, _}] -> Process.alive?(pid)
        _ -> false
      end

    runner or (is_integer(pgid) and pgid > 1 and ProcessGroup.alive?(pgid))
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
