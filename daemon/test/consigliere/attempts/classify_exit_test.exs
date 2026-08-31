defmodule Consigliere.Attempts.ClassifyExitTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Attempts.Attempt
  alias Consigliere.DispatchOperations
  alias Consigliere.Fixtures
  alias Consigliere.GlobalScheduler
  alias Consigliere.Missions
  alias Consigliere.Repo

  setup do
    Fixtures.reset_phase1_tables!()
    GlobalScheduler.reset()
    :ok
  end

  defp running_attempt! do
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())
    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Fixtures.grant_work_quietly(mission.id, Actor.boss())

    {:ok, %{attempt: attempt}} =
      Missions.start(mission.id, Actor.system(), %{
        workspace_path: "/tmp/cs-#{System.unique_integer([:positive])}"
      })

    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())

    {:ok, attempt} =
      Attempts.mark_running(attempt.id, Actor.system(), %{fencing_token: attempt.fencing_token})

    attempt
  end

  test "session.completed plus verified death without a SHA is a protocol failure" do
    attempt = running_attempt!()

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
  end

  test "exit 0 without session.completed is lost not completed" do
    attempt = running_attempt!()

    {:ok, lost} =
      Attempts.classify_exit(attempt.id, %{
        process_group: :dead_verified,
        exit_status: 0,
        session_completed: false
      })

    assert lost.status == "lost"
  end

  test "session.failed plus verified death preserves the failure class" do
    attempt = running_attempt!()

    {:ok, failed} =
      Attempts.classify_exit(attempt.id, %{
        process_group: :dead_verified,
        exit_status: 1,
        session_failed: true,
        exit_classification: "tool_error"
      })

    assert failed.status == "failed"
    assert failed.exit_classification == "tool_error"
  end

  test "unverified death keeps the scheduler slot occupied" do
    attempt = running_attempt!()
    {:ok, _operation} = DispatchOperations.ensure(attempt, %{slot_state: "granted"})

    assert {:ok, :granted} = GlobalScheduler.request_slot(attempt.mission_id)

    assert {:ok, lost} =
             Attempts.classify_exit(attempt.id, %{
               process_group: :unconfirmed,
               exit_status: nil
             })

    assert lost.status == "lost"
    assert {:error, :busy} = GlobalScheduler.request_slot("another-mission")
    assert DispatchOperations.get_by_attempt(attempt.id).slot_state == "unknown"

    assert {:ok, _terminal} =
             Attempts.classify_exit(attempt.id, %{process_group: :dead_verified})

    assert DispatchOperations.get_by_attempt(attempt.id).slot_state == "released"
    assert {:ok, :granted} = GlobalScheduler.request_slot("after-verified-death")
  end

  test "unverified death during cancellation is reconciled as lost" do
    attempt = running_attempt!()

    {:ok, attempt} =
      Repo.update(
        Attempt.changeset(attempt, %{status: "terminating", exit_classification: "canceled"})
      )

    assert {:ok, lost} =
             Attempts.classify_exit(attempt.id, %{process_group: :unconfirmed})

    assert lost.status == "lost"
    assert lost.exit_classification == "canceled"
  end

  test "verified death after an unverified cancellation releases the held slot" do
    attempt = running_attempt!()
    {:ok, _operation} = DispatchOperations.ensure(attempt, %{slot_state: "granted"})
    assert {:ok, :granted} = GlobalScheduler.request_slot(attempt.mission_id)

    {:ok, attempt} =
      Repo.update(
        Attempt.changeset(attempt, %{status: "terminating", exit_classification: "canceled"})
      )

    assert {:ok, lost} =
             Attempts.classify_exit(attempt.id, %{process_group: :unconfirmed})

    assert lost.status == "lost"
    assert DispatchOperations.get_by_attempt(attempt.id).slot_state == "unknown"
    assert {:error, :busy} = GlobalScheduler.request_slot("held-after-unverified-cancel")

    assert {:ok, _terminal} =
             Attempts.classify_exit(attempt.id, %{process_group: :dead_verified})

    assert DispatchOperations.get_by_attempt(attempt.id).slot_state == "released"
    assert {:ok, :granted} = GlobalScheduler.request_slot("released-after-verified-death")
  end

  test "verified terminal exit releases every durable slot state" do
    attempt = running_attempt!()
    {:ok, _operation} = DispatchOperations.ensure(attempt, %{slot_state: "granted"})
    assert {:ok, :granted} = GlobalScheduler.request_slot(attempt.mission_id)

    assert {:ok, terminal} =
             Attempts.classify_exit(attempt.id, %{
               process_group: :dead_verified,
               exit_status: 1,
               session_failed: true,
               exit_classification: "tool_error"
             })

    assert terminal.status == "failed"
    assert DispatchOperations.get_by_attempt(attempt.id).slot_state == "released"
    assert {:ok, :granted} = GlobalScheduler.request_slot("after-durable-release")
  end

  test "a durable slot persistence failure does not release scheduler capacity" do
    attempt = running_attempt!()
    {:ok, _operation} = DispatchOperations.ensure(attempt, %{slot_state: "granted"})
    assert {:ok, :granted} = GlobalScheduler.request_slot(attempt.mission_id)

    Repo.update_all(DispatchOperations.DispatchOperation, set: [slot_state: "corrupt"])

    assert {:error, {:dispatch_slot_persistence_failed, _reason}} =
             Attempts.classify_exit(attempt.id, %{
               process_group: :dead_verified,
               exit_status: 1,
               session_failed: true,
               exit_classification: "tool_error"
             })

    assert Repo.get!(Attempt, attempt.id).status == "running"
    assert {:error, :busy} = GlobalScheduler.request_slot("after-persistence-failure")
  end
end
