defmodule Consigliere.DatabaseWriterAtomicityTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Fixtures
  alias Consigliere.Missions
  alias Consigliere.Attempts
  alias Consigliere.Gates
  alias Consigliere.Repo
  alias Consigliere.Gates.Gate
  alias Consigliere.Questions.Question
  alias Consigliere.MissionBlockers.MissionBlocker

  setup do
    Fixtures.reset_phase1_tables!()
    :ok
  end

  test "a failed question insert inside needs_decision rolls back the gate status and writes no new event" do
    {:ok, mission} =
      Missions.create(Fixtures.mission_attrs(), Actor.boss())

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Fixtures.grant_work_quietly(mission.id, Actor.boss())

    {:ok, %{attempt: attempt}} =
      Missions.start(mission.id, Actor.system(), %{
        workspace_path: "/tmp/cs-#{System.unique_integer([:positive])}"
      })

    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())

    {:ok, attempt} =
      Attempts.mark_running(attempt.id, Actor.system(), %{fencing_token: attempt.fencing_token})

    {:ok, gate} =
      Gates.create(mission.id, Actor.system(), %{
        gate_type: "review",
        input_sha: "in",
        base_sha: "base",
        policy_hash: "p"
      })

    {:ok, gate} = Gates.start(gate.id, Actor.system(), %{managed_run_id: "run-1"})

    assert {:error, %Ecto.Changeset{}} =
             Gates.needs_decision(gate.id, Actor.system(), %{
               finding_digest: "d",
               managed_run_id: "run-1",
               question_attrs: %{
                 attempt_id: attempt.id,
                 request_id: "g1",
                 blocking_scope: "mission",
                 requested_authority: "boss"
               }
             })

    assert Repo.get!(Gate, gate.id).status == "running"
    assert Repo.aggregate(Question, :count) == 0
    assert Repo.aggregate(MissionBlocker, :count) == 0
    assert Fixtures.event_types(gate.id) == ["gate.created", "gate.started"]
  end
end
