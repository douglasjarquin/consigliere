defmodule Consigliere.ProgressionTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Fixtures
  alias Consigliere.Gates.Gate
  alias Consigliere.Git
  alias Consigliere.Incidents.Incident
  alias Consigliere.Missions
  alias Consigliere.Missions.Mission
  alias Consigliere.Progression
  alias Consigliere.Repo

  setup do
    Fixtures.reset_phase1_tables!()
    Consigliere.GlobalScheduler.reset()
    root = Path.join(System.tmp_dir!(), "cs-prog-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "successful Attempt with a commit imports the SHA, runs Gates, and reaches ready_for_review",
       %{root: root} do
    %{attempt: attempt, mission: mission, sha: sha} = completed_with_commit!(root)

    assert {:ok, _} = Progression.run(attempt.id, forced_outcome: :passed)

    attempt = Repo.get!(Attempt, attempt.id)
    mission = Repo.get!(Mission, mission.id)
    assert attempt.status == "completed"
    assert mission.current_checkpoint_sha == sha
    assert mission.phase == "ready_for_review"

    gate = Repo.get_by!(Gate, mission_id: mission.id, gate_type: "review")
    assert gate.status == "passed"
    assert gate.input_sha == sha
  end

  test "semantic completion without a commit SHA is a protocol failure, not completed", %{
    root: root
  } do
    %{attempt: attempt, mission: mission} = running_in_workspace!(root)

    {:ok, attempt} =
      Repo.update(Attempt.changeset(attempt, %{exit_classification: "completed"}))

    {:ok, done} =
      Attempts.classify_exit(attempt.id, %{
        process_group: :dead_verified,
        exit_status: 0,
        session_completed: true
      })

    assert done.status == "failed"
    assert done.exit_classification == "protocol_failure"
    assert Repo.get!(Mission, mission.id).phase == "active"
    assert Repo.get!(Mission, mission.id).current_checkpoint_sha == nil
    assert Repo.aggregate(Incident, :count) >= 1
  end

  test "duplicate progression of the same Attempt imports once", %{root: root} do
    %{attempt: attempt, mission: mission, sha: sha} = completed_with_commit!(root)

    assert {:ok, _} = Progression.run(attempt.id, forced_outcome: :passed)
    assert {:ok, _} = Progression.run(attempt.id, forced_outcome: :passed)

    assert Repo.get!(Mission, mission.id).current_checkpoint_sha == sha
    assert Repo.aggregate(Gate, :count) == 1
  end

  test "a Question checkpoint imports the SHA and leaves the Mission active", %{root: root} do
    %{attempt: attempt, mission: mission, workspace: workspace} =
      running_in_workspace!(root)

    File.write!(Path.join(workspace, "note.txt"), "ask\n")
    sha = Git.commit_all(workspace, "checkpoint")

    {:ok, attempt} =
      Attempts.request_checkpoint(attempt.id, Actor.system(), %{reported_checkpoint_sha: sha})

    assert {:ok, _} = Progression.run(attempt.id, forced_outcome: :passed)

    attempt = Repo.get!(Attempt, attempt.id)
    mission = Repo.get!(Mission, mission.id)
    assert attempt.status == "checkpointed"
    assert mission.current_checkpoint_sha == sha
    assert mission.phase == "active"
  end

  test "a SHA outside trusted ancestry fails closed with an Incident", %{root: root} do
    %{attempt: attempt, mission: mission, workspace: workspace} = running_in_workspace!(root)
    other = Path.join(root, "other")
    Git.init_workspace(other)
    File.write!(Path.join(other, "x.txt"), "unrelated\n")
    foreign = Git.commit_all(other, "foreign")

    {:ok, _} =
      Repo.update(Attempt.changeset(attempt, %{reported_checkpoint_sha: foreign}))

    assert {:error, _} = Progression.run(attempt.id)
    assert Repo.get!(Mission, mission.id).current_checkpoint_sha == nil
    assert Repo.get!(Attempt, attempt.id).status == "failed"
    assert Repo.aggregate(Incident, :count) >= 1
    File.dir?(workspace)
  end

  test "cs why names the post-Attempt step after a completed import", %{root: root} do
    %{attempt: attempt, mission: mission} = completed_with_commit!(root)
    assert Progression.next_action(Repo.get!(Mission, mission.id)) == :import
    assert {:ok, _} = Progression.run(attempt.id, forced_outcome: :passed)
    assert Progression.next_action(Repo.get!(Mission, mission.id)) == :review
  end

  defp running_in_workspace!(root) do
    workspace = Path.join(root, "workspace")
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())
    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Fixtures.grant_work_quietly(mission.id, Actor.boss())

    {:ok, %{attempt: attempt, workspace: ws, mission: mission}} =
      Missions.start(mission.id, Actor.system(), %{workspace_path: workspace})

    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())

    {:ok, attempt} =
      Attempts.mark_running(attempt.id, Actor.system(), %{fencing_token: attempt.fencing_token})

    Git.init_workspace(workspace)
    File.write!(Path.join(workspace, "work.txt"), "done\n")
    sha = Git.commit_all(workspace, "work")
    %{attempt: attempt, mission: mission, workspace: workspace, ws: ws, sha: sha}
  end

  defp completed_with_commit!(root) do
    ctx = running_in_workspace!(root)

    {:ok, attempt} =
      Repo.update(
        Attempt.changeset(ctx.attempt, %{
          exit_classification: "completed",
          reported_checkpoint_sha: ctx.sha
        })
      )

    %{ctx | attempt: attempt}
  end
end
