defmodule Consigliere.ProgressionTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Fixtures
  alias Consigliere.Gates.Gate
  alias Consigliere.GlobalScheduler
  alias Consigliere.Git
  alias Consigliere.Harness.Events
  alias Consigliere.Home
  alias Consigliere.Incidents.Incident
  alias Consigliere.Missions
  alias Consigliere.Missions.Mission
  alias Consigliere.Progression
  alias Consigliere.Projects
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

    assert {:ok, _} =
             Progression.run(attempt.id, process_group: :dead_verified, forced_outcome: :passed)

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

  test "protocol failure classification releases the scheduler slot", %{root: root} do
    %{attempt: attempt, mission: mission} = running_in_workspace!(root)

    assert GlobalScheduler.request_slot(mission.id) in [{:ok, :granted}, {:ok, :held}]

    {:ok, attempt} =
      Repo.update(Attempt.changeset(attempt, %{exit_classification: "protocol_failure"}))

    {:ok, failed} =
      Attempts.classify_exit(attempt.id, %{
        process_group: :dead_verified,
        exit_status: 1,
        session_failed: true,
        exit_classification: "protocol_failure"
      })

    assert failed.status == "failed"
    assert {:ok, :granted} = GlobalScheduler.request_slot("next-mission")
  end

  test "duplicate progression of the same Attempt imports once", %{root: root} do
    %{attempt: attempt, mission: mission, sha: sha} = completed_with_commit!(root)

    assert {:ok, _} =
             Progression.run(attempt.id, process_group: :dead_verified, forced_outcome: :passed)

    assert {:ok, _} =
             Progression.run(attempt.id, process_group: :dead_verified, forced_outcome: :passed)

    assert Repo.get!(Mission, mission.id).current_checkpoint_sha == sha
    assert Repo.aggregate(Gate, :count) == 1
  end

  test "does not import when a durable progression checkpoint cannot be recorded", %{
    root: root
  } do
    %{attempt: attempt, mission: mission, project: project, sha: sha} =
      completed_with_commit!(root)

    Repo.query!("""
    CREATE TRIGGER attempt_results_block_progression
    BEFORE UPDATE OF status ON attempt_results
    BEGIN
      SELECT RAISE(ABORT, 'progression status write blocked');
    END
    """)

    on_exit(fn -> Repo.query("DROP TRIGGER IF EXISTS attempt_results_block_progression") end)

    assert {:error, {:progression_failed, _reason}} =
             Progression.run(attempt.id, process_group: :dead_verified, forced_outcome: :passed)

    assert Repo.get!(Attempt, attempt.id).status == "failed"
    assert Repo.get!(Mission, mission.id).phase == "active"
    assert Repo.get!(Mission, mission.id).current_checkpoint_sha == nil

    assert {:error, _} =
             Git.read_ref(project.trusted_mirror_path, Git.result_ref(project.id, attempt.id))

    assert sha != Repo.get!(Mission, mission.id).current_checkpoint_sha
  end

  test "retries an imported result after the durable imported state write is interrupted", %{
    root: root
  } do
    %{attempt: attempt, mission: mission, project: project, sha: sha} =
      completed_with_commit!(root)

    assert GlobalScheduler.request_slot(mission.id) in [{:ok, :granted}, {:ok, :held}]

    Repo.query!("""
    CREATE TRIGGER attempt_results_interrupt_import
    BEFORE UPDATE OF status ON attempt_results
    WHEN NEW.status = 'imported'
    BEGIN
      SELECT RAISE(ABORT, 'import state write interrupted');
    END
    """)

    on_exit(fn -> Repo.query("DROP TRIGGER IF EXISTS attempt_results_interrupt_import") end)

    assert {:error, {:progression_failed, :result_import_persist_failed}} =
             Progression.run(attempt.id, process_group: :dead_verified, forced_outcome: :passed)

    assert Repo.get!(Attempt, attempt.id).status == "running"

    assert Consigliere.AttemptResults.by_attempt(attempt.id).status in [
             "death_verified",
             "commit_verified"
           ]

    {:ok, imported_sha} =
      Git.read_ref(project.trusted_mirror_path, Git.result_ref(project.id, attempt.id))

    assert imported_sha == sha

    Repo.query!("DROP TRIGGER IF EXISTS attempt_results_interrupt_import")

    assert {:ok, _} =
             Progression.run(attempt.id, process_group: :dead_verified, forced_outcome: :passed)

    assert Repo.get!(Attempt, attempt.id).status == "completed"
    assert Repo.get!(Mission, mission.id).current_checkpoint_sha == sha
  end

  test "a Question checkpoint imports the SHA and leaves the Mission active", %{root: root} do
    %{attempt: attempt, mission: mission, workspace: workspace, ws: ws} =
      running_in_workspace!(root)

    File.write!(Path.join(workspace, "note.txt"), "ask\n")
    sha = Git.commit_all(workspace, "checkpoint")
    record_checkpoint_event!(attempt, 1)

    {:ok, attempt} =
      Attempts.request_checkpoint(
        attempt.id,
        Actor.attempt(attempt.id, attempt.fencing_token),
        result_attrs(%{mission: mission, ws: ws, attempt: attempt}, "checkpoint", sha, 1)
      )

    assert {:ok, _} =
             Progression.run(attempt.id, process_group: :dead_verified, forced_outcome: :passed)

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

    record_terminal_event!(attempt, 1)

    {:ok, _} =
      Attempts.report_completion(
        attempt.id,
        Actor.attempt(attempt.id, attempt.fencing_token),
        result_attrs(
          %{
            mission: mission,
            ws: Repo.get!(Consigliere.Workspaces.Workspace, attempt.workspace_id),
            attempt: attempt
          },
          "completed",
          foreign,
          1
        )
      )

    assert {:error, _} = Progression.run(attempt.id, process_group: :dead_verified)
    assert Repo.get!(Mission, mission.id).current_checkpoint_sha == nil
    assert Repo.get!(Attempt, attempt.id).status == "failed"
    assert Repo.aggregate(Incident, :count) >= 1
    File.dir?(workspace)
  end

  test "cs why names the post-Attempt step after a completed import", %{root: root} do
    %{attempt: attempt, mission: mission} = completed_with_commit!(root)
    assert Progression.next_action(Repo.get!(Mission, mission.id)) == :import

    assert {:ok, _} =
             Progression.run(attempt.id, process_group: :dead_verified, forced_outcome: :passed)

    assert Progression.next_action(Repo.get!(Mission, mission.id)) == :review
  end

  defp running_in_workspace!(root) do
    source = Path.join(root, "source")
    Git.init_workspace(source)
    File.write!(Path.join(source, "README"), "base\n")
    base_sha = Git.commit_all(source, "base")

    {:ok, project} =
      Projects.register(
        %{name: "progression", repository_path: source, repository_url: "file://#{source}"},
        Actor.boss()
      )

    {:ok, mission} =
      Missions.create(
        Fixtures.mission_attrs(%{project_id: project.id, base_sha: base_sha}),
        Actor.boss()
      )

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Missions.grant_work_authorization(mission.id, Actor.boss())
    workspace_path = Path.join(Home.workspaces_dir(), mission.id)

    {:ok, %{attempt: attempt, workspace: ws, mission: mission}} =
      Missions.start(mission.id, Actor.system(), %{workspace_path: workspace_path})

    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())

    {:ok, attempt} =
      Attempts.mark_running(attempt.id, Actor.system(), %{fencing_token: attempt.fencing_token})

    File.write!(Path.join(ws.path, "work.txt"), "done\n")
    sha = Git.commit_all(ws.path, "work")
    %{attempt: attempt, mission: mission, workspace: ws.path, ws: ws, sha: sha, project: project}
  end

  defp completed_with_commit!(root) do
    ctx = running_in_workspace!(root)
    record_terminal_event!(ctx.attempt, 1)

    {:ok, attempt} =
      Attempts.report_completion(
        ctx.attempt.id,
        Actor.attempt(ctx.attempt.id, ctx.attempt.fencing_token),
        result_attrs(ctx, "completed", ctx.sha, 1)
      )

    %{ctx | attempt: attempt}
  end

  defp record_terminal_event!(attempt, sequence) do
    assert {:ok, :accepted} =
             Events.ingest(
               %{
                 "event_id" => "progression-terminal-#{attempt.id}",
                 "type" => "session.completed",
                 "native_sequence" => sequence,
                 "attempt_id" => attempt.id,
                 "payload" => %{}
               },
               Actor.attempt(attempt.id, attempt.fencing_token)
             )
  end

  defp record_checkpoint_event!(attempt, sequence) do
    assert {:ok, :accepted} =
             Events.ingest(
               %{
                 "event_id" => "progression-checkpoint-#{attempt.id}",
                 "type" => "turn.completed",
                 "native_sequence" => sequence,
                 "attempt_id" => attempt.id,
                 "payload" => %{}
               },
               Actor.attempt(attempt.id, attempt.fencing_token)
             )
  end

  defp result_attrs(ctx, kind, sha, sequence) do
    %{
      mission_id: ctx.mission.id,
      project_id: ctx.mission.project_id,
      workspace_id: ctx.ws.id,
      workspace_generation: ctx.ws.lease_id,
      base_sha: ctx.mission.base_sha,
      fencing_generation: ctx.attempt.fencing_token,
      terminal_sequence: sequence,
      result_sha: sha,
      result_kind: kind
    }
  end
end
