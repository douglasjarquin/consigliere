defmodule Consigliere.Made.ValidateTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Decisions.Decision
  alias Consigliere.Fixtures
  alias Consigliere.Gates
  alias Consigliere.Gates.Gate
  alias Consigliere.Made.Validate
  alias Consigliere.MissionBlockers.MissionBlocker
  alias Consigliere.Missions
  alias Consigliere.Questions
  alias Consigliere.Questions.Question
  alias Consigliere.Repo

  setup do
    Fixtures.reset_phase1_tables!()
    :ok
  end

  defp running_gate!(sha \\ "sha-a") do
    {:ok, mission} =
      Missions.create(Fixtures.mission_attrs(), Actor.boss())

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Missions.grant_work_authorization(mission.id, Actor.boss())

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
        input_sha: sha,
        base_sha: "base",
        policy_hash: "p1"
      })

    {:ok, gate} = Gates.start(gate.id, Actor.system(), %{managed_run_id: "run-#{sha}"})
    {attempt, gate}
  end

  test "needs_decision leaves zero live validator process and persists Gate plus Question" do
    {attempt, gate} = running_gate!()
    result = Validate.run(gate, attempt)
    assert result.outcome == :needs_decision
    assert result.live_pid == nil
    assert result.exit_code == 2
    assert Repo.get!(Gate, gate.id).status == "needs_decision"
    assert Repo.aggregate(Question, :count) == 1
  end

  test "a rerun against the same SHA after a Decision is idempotent and passes" do
    {attempt, gate} = running_gate!("sha-a")
    Validate.run(gate, attempt)
    question = Repo.one!(Question)
    {:ok, question} = Questions.answer(question.id, Actor.boss(), %{answer: "waive"})

    {:ok, decision} =
      Repo.insert(
        Decision.changeset(%Decision{}, %{
          mission_id: attempt.mission_id,
          question_id: question.id,
          scope: "sha_bound",
          input_sha: "sha-a",
          base_sha: "base",
          granted_by_principal: "boss"
        })
      )

    {:ok, gate} = Gates.rerun_after_decision(gate.id, Actor.system(), decision.id)
    assert Repo.aggregate(from(b in MissionBlocker, where: b.status == "open"), :count) == 0
    {:ok, gate} = Gates.start(gate.id, Actor.system(), %{managed_run_id: "run-2"})

    result =
      Validate.run(gate, attempt,
        decisions: [
          %{"fingerprint" => "fp-default", "scope" => "sha_bound", "input_sha" => "sha-a"}
        ]
      )

    assert result.outcome == :passed
    assert Repo.get!(Gate, gate.id).status == "passed"

    assert {:error, {:illegal_transition, _}} =
             Gates.rerun_after_decision(gate.id, Actor.system(), decision.id)
  end

  test "a sha_bound Decision does not apply to a different input SHA" do
    {attempt, gate_a} = running_gate!("sha-a")
    Validate.run(gate_a, attempt)

    {:ok, gate_b} =
      Gates.create(attempt.mission_id, Actor.system(), %{
        gate_type: "review",
        input_sha: "sha-b",
        base_sha: "base",
        policy_hash: "p1"
      })

    {:ok, gate_b} = Gates.start(gate_b.id, Actor.system(), %{managed_run_id: "run-b"})

    result =
      Validate.run(gate_b, attempt,
        decisions: [
          %{"fingerprint" => "fp-default", "scope" => "sha_bound", "input_sha" => "sha-a"}
        ]
      )

    assert result.outcome == :needs_decision
    assert Repo.get!(Gate, gate_b.id).status == "needs_decision"
  end
end
