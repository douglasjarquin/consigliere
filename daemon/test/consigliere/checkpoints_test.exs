defmodule Consigliere.CheckpointsTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Checkpoints
  alias Consigliere.Fixtures
  alias Consigliere.Git
  alias Consigliere.Missions
  alias Consigliere.Missions.Mission
  alias Consigliere.Repo
  alias Consigliere.Workspaces.Workspace

  setup do
    Fixtures.reset_phase1_tables!()
    Consigliere.GlobalScheduler.reset()

    root = Path.join(System.tmp_dir!(), "cs-ckpt-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    mirror = Path.join(root, "trusted.git")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{workspace: workspace, mirror: mirror}
  end

  defp checkpoint_ready!(workspace) do
    {:ok, mission} =
      Missions.create(Fixtures.mission_attrs(), Actor.boss())

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Missions.grant_work_authorization(mission.id, Actor.boss())

    {:ok, %{attempt: attempt, workspace: ws}} =
      Missions.start(mission.id, Actor.system(), %{workspace_path: workspace})

    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())

    {:ok, attempt} =
      Attempts.mark_running(attempt.id, Actor.system(), %{fencing_token: attempt.fencing_token})

    Git.init_workspace(workspace)
    File.write!(Path.join(workspace, "work.txt"), "done\n")
    sha = Git.commit_all(workspace, "work")

    {:ok, attempt} =
      Attempts.request_checkpoint(attempt.id, Actor.system(), %{reported_checkpoint_sha: sha})

    %{mission: mission, attempt: attempt, workspace: ws, sha: sha}
  end

  test "import_after_death writes the SHA only after git import, never without verified death",
       %{workspace: workspace, mirror: mirror} do
    %{attempt: attempt, mission: mission, sha: sha} = checkpoint_ready!(workspace)

    assert {:error, {:illegal_transition, %{reason: :death_not_verified}}} =
             Checkpoints.import_after_death(attempt.id,
               process_group: :unconfirmed,
               workspace_path: workspace,
               mirror_path: mirror,
               sha: sha
             )

    assert Repo.get!(Mission, mission.id).current_checkpoint_sha == nil

    assert {:ok, %{attempt: updated}} =
             Checkpoints.import_after_death(attempt.id,
               process_group: :dead_verified,
               workspace_path: workspace,
               mirror_path: mirror,
               sha: sha
             )

    assert updated.status == "checkpointed"
    assert Repo.get!(Mission, mission.id).current_checkpoint_sha == sha
    assert Git.mirror_has_commit?(mirror, sha)
    assert Repo.get!(Workspace, attempt.workspace_id).status == "daemon_exclusive"
  end
end
