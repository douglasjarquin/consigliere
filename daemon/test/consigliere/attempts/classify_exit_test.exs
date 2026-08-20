defmodule Consigliere.Attempts.ClassifyExitTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Fixtures
  alias Consigliere.Missions
  alias Consigliere.Repo

  setup do
    Fixtures.reset_phase1_tables!()
    :ok
  end

  defp running_attempt! do
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())
    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Missions.grant_work_authorization(mission.id, Actor.boss())

    {:ok, %{attempt: attempt}} =
      Missions.start(mission.id, Actor.system(), %{
        workspace_path: "/tmp/cs-#{System.unique_integer([:positive])}"
      })

    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())

    {:ok, attempt} =
      Attempts.mark_running(attempt.id, Actor.system(), %{fencing_token: attempt.fencing_token})

    attempt
  end

  test "session.completed plus verified death completes the Attempt" do
    attempt = running_attempt!()

    {:ok, attempt} =
      Repo.update(Attempt.changeset(attempt, %{exit_classification: "completed"}))

    {:ok, done} =
      Attempts.classify_exit(attempt.id, %{
        process_group: :dead_verified,
        exit_status: 0,
        session_completed: true
      })

    assert done.status == "completed"
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
end
