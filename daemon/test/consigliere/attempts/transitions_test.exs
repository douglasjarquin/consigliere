defmodule Consigliere.Attempts.TransitionsTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Consigliere.Actor
  alias Consigliere.DispatchOperations
  alias Consigliere.Fixtures
  alias Consigliere.GlobalScheduler
  alias Consigliere.Missions
  alias Consigliere.Attempts
  alias Consigliere.Questions
  alias Consigliere.Workspaces
  alias Consigliere.Repo
  alias Consigliere.Workspaces.Workspace

  setup do
    Fixtures.reset_phase1_tables!()
    GlobalScheduler.reset()
    :ok
  end

  defp started_attempt! do
    {:ok, mission} =
      Missions.create(Fixtures.mission_attrs(), Actor.boss())

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Fixtures.grant_work_quietly(mission.id, Actor.boss())

    {:ok, %{mission: mission, attempt: attempt, workspace: workspace}} =
      Missions.start(mission.id, Actor.system(), %{
        workspace_path: "/tmp/cs-#{System.unique_integer([:positive])}"
      })

    %{mission: mission, attempt: attempt, workspace: workspace}
  end

  defp running_attempt! do
    %{attempt: attempt} = ctx = started_attempt!()
    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())

    {:ok, attempt} =
      Attempts.mark_running(attempt.id, Actor.system(), %{
        fencing_token: attempt.fencing_token,
        runner_pid: 11,
        harness_pid: 12,
        pgid: 13
      })

    Map.put(ctx, :attempt, attempt)
  end

  test "schedule then spawn then running persists runner identity" do
    %{attempt: attempt} = running_attempt!()
    assert attempt.status == "running"
    assert attempt.runner_pid == 11
    assert attempt.pgid == 13
    assert "attempt.started" in Fixtures.event_types(attempt.id)
  end

  test "mark_running with the wrong fencing token is fenced" do
    %{attempt: attempt} = started_attempt!()
    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())

    assert {:error, {:fenced, _}} =
             Attempts.mark_running(attempt.id, Actor.system(), %{fencing_token: "nope"})
  end

  test "record_checkpointed without verified death does not advance the mission sha" do
    %{attempt: attempt, mission: mission} = running_attempt!()

    {:ok, _} =
      Attempts.request_checkpoint(attempt.id, Actor.system(), %{reported_checkpoint_sha: "sha1"})

    assert {:error, {:illegal_transition, %{reason: :death_not_verified}}} =
             Attempts.record_checkpointed(attempt.id, Actor.system(), %{imported_sha: "sha1"})

    assert Repo.get!(Consigliere.Missions.Mission, mission.id).current_checkpoint_sha == nil
  end

  test "record_checkpointed with verified death sets the mission checkpoint and daemon_exclusive workspace" do
    %{attempt: attempt, mission: mission, workspace: workspace} = running_attempt!()

    {:ok, _} =
      Attempts.request_checkpoint(attempt.id, Actor.system(), %{reported_checkpoint_sha: "sha1"})

    {:ok, %{attempt: attempt}} =
      Attempts.record_checkpointed(attempt.id, Actor.system(), %{
        imported_sha: "sha1",
        process_group: :dead_verified
      })

    assert attempt.status == "checkpointed"
    assert Repo.get!(Consigliere.Missions.Mission, mission.id).current_checkpoint_sha == "sha1"
    assert Repo.get!(Workspace, workspace.id).status == "daemon_exclusive"
  end

  test "record_checkpointed releases durable and in-memory capacity" do
    %{attempt: attempt, mission: mission} = running_attempt!()
    assert {:ok, :granted} = GlobalScheduler.request_slot(mission.id)
    {:ok, _operation} = DispatchOperations.ensure(attempt, %{slot_state: "granted"})

    {:ok, _} =
      Attempts.request_checkpoint(attempt.id, Actor.system(), %{reported_checkpoint_sha: "sha1"})

    assert {:ok, _} =
             Attempts.record_checkpointed(attempt.id, Actor.system(), %{
               imported_sha: "sha1",
               process_group: :dead_verified
             })

    assert DispatchOperations.get_by_attempt(attempt.id).slot_state == "released"
    assert {:ok, :granted} = GlobalScheduler.request_slot("mission-b")
  end

  test "mark_lost with unconfirmed inventory quarantines the workspace and opens an incident" do
    %{attempt: attempt, workspace: workspace} = running_attempt!()

    {:ok, attempt} =
      Attempts.mark_lost(attempt.id, Actor.system(), %{inventory: :unconfirmed})

    assert attempt.status == "lost"
    assert Repo.get!(Workspace, workspace.id).status == "quarantined"
    assert Repo.aggregate(Consigliere.Incidents.Incident, :count) == 1
  end

  test "release on a quarantined workspace is illegal" do
    %{workspace: workspace} = running_attempt!()
    {:ok, _} = Workspaces.quarantine(workspace.id, Actor.system(), "unsafe")

    assert {:error, {:illegal_transition, %{reason: :not_daemon_exclusive}}} =
             Workspaces.release(workspace.id, Actor.system())
  end

  test "supersede invalidates the old fencing token and supersedes attempt-scoped questions only" do
    %{attempt: attempt} = running_attempt!()

    {:ok, attempt_q} =
      Questions.open(
        %{
          attempt_id: attempt.id,
          request_id: "a1",
          blocking_scope: "attempt",
          requested_authority: "boss",
          prompt: "subtask?"
        },
        Actor.attempt(attempt.id, attempt.fencing_token)
      )

    {:ok, mission_q} =
      Questions.open(
        %{
          attempt_id: attempt.id,
          request_id: "m1",
          blocking_scope: "mission",
          requested_authority: "boss",
          prompt: "land it?"
        },
        Actor.attempt(attempt.id, attempt.fencing_token)
      )

    {:ok, %{attempt: old, replacement: new}} =
      Attempts.supersede(attempt.id, Actor.system(), %{role: "soldier", harness: "claude"})

    assert old.status == "superseded"
    assert new.retry_of_attempt_id == old.id
    assert Repo.get!(Consigliere.Questions.Question, attempt_q.id).status == "superseded"
    assert Repo.get!(Consigliere.Questions.Question, mission_q.id).status == "open"

    assert {:error, {:fenced, _}} =
             Questions.open(
               %{
                 attempt_id: old.id,
                 request_id: "late",
                 blocking_scope: "attempt",
                 requested_authority: "boss",
                 prompt: "late"
               },
               Actor.attempt(old.id, old.fencing_token)
             )
  end

  test "superseding a planned Attempt leaves only the replacement recoverable" do
    %{attempt: old} = started_attempt!()

    assert {:ok, %{attempt: superseded, replacement: replacement}} =
             Attempts.supersede(old.id, Actor.system(), %{role: "soldier", harness: "claude"})

    assert superseded.status == "superseded"
    assert replacement.retry_of_attempt_id == old.id
    assert replacement.status == "planned"

    assert Repo.aggregate(
             from(a in Consigliere.Attempts.Attempt,
               where: a.mission_id == ^old.mission_id and a.status in ["planned", "starting"]
             ),
             :count
           ) == 1
  end
end
