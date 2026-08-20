defmodule Consigliere.Gates.TransitionsTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Consigliere.Actor
  alias Consigliere.Fixtures
  alias Consigliere.Missions
  alias Consigliere.Attempts
  alias Consigliere.Gates
  alias Consigliere.Questions
  alias Consigliere.Repo
  alias Consigliere.Gates.Gate
  alias Consigliere.Questions.Question
  alias Consigliere.MissionBlockers.MissionBlocker
  alias Consigliere.MissionValidationLedgers.MissionValidationLedger
  alias Consigliere.Incidents.Incident
  alias Consigliere.Decisions.Decision

  setup do
    Fixtures.reset_phase1_tables!()
    :ok
  end

  defp running_attempt! do
    {:ok, mission} =
      Missions.create(Fixtures.mission_attrs(), Actor.boss())

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Fixtures.grant_work_quietly(mission.id, Actor.boss())

    {:ok, %{mission: mission, attempt: attempt}} =
      Missions.start(mission.id, Actor.system(), %{
        workspace_path: "/tmp/cs-#{System.unique_integer([:positive])}"
      })

    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())

    {:ok, attempt} =
      Attempts.mark_running(attempt.id, Actor.system(), %{fencing_token: attempt.fencing_token})

    %{mission: mission, attempt: attempt}
  end

  defp running_gate!(overrides \\ %{}) do
    %{mission: mission, attempt: attempt} = running_attempt!()

    attrs =
      Map.merge(
        %{gate_type: "review", input_sha: "in1", base_sha: "base", policy_hash: "p1"},
        overrides
      )

    {:ok, gate} = Gates.create(mission.id, Actor.system(), attrs)
    {:ok, gate} = Gates.start(gate.id, Actor.system(), %{managed_run_id: "run-1"})
    %{mission: mission, attempt: attempt, gate: gate}
  end

  defp ask!(gate, attempt, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          finding_digest: "fp-a",
          managed_run_id: gate.managed_run_id,
          question_attrs: %{
            attempt_id: attempt.id,
            request_id: "g1",
            blocking_scope: "mission",
            requested_authority: "boss",
            prompt: "waiver?"
          }
        },
        overrides
      )

    {:ok, result} = Gates.needs_decision(gate.id, Actor.system(), attrs)
    result
  end

  defp grant!(gate, question, overrides \\ %{}) do
    {:ok, decision} =
      Repo.insert(
        Decision.changeset(
          %Decision{},
          Map.merge(
            %{
              mission_id: gate.mission_id,
              question_id: question.id,
              scope: "sha_bound",
              granted_by_principal: "boss",
              input_sha: gate.input_sha,
              base_sha: gate.base_sha
            },
            overrides
          )
        )
      )

    decision
  end

  defp open_validation(gate) do
    Repo.all(
      from(b in MissionBlocker,
        where: b.kind == "validation" and b.status == "open" and b.subject_id == ^gate.id
      )
    )
  end

  defp open_blockers(mission_id) do
    Repo.all(from(b in MissionBlocker, where: b.mission_id == ^mission_id and b.status == "open"))
  end

  test "duplicate identity is rejected until the first gate is invalidated" do
    %{mission: mission, gate: gate} = running_gate!()

    {:ok, gate} =
      Gates.pass(gate.id, Actor.system(), %{
        input_sha: "in1",
        base_sha: "base",
        managed_run_id: "run-1"
      })

    assert {:error, %Ecto.Changeset{}} =
             Gates.create(mission.id, Actor.system(), %{
               gate_type: "review",
               input_sha: "in1",
               base_sha: "base",
               policy_hash: "p1"
             })

    {:ok, _} = Gates.invalidate(gate.id, Actor.system())

    assert {:ok, _} =
             Gates.create(mission.id, Actor.system(), %{
               gate_type: "review",
               input_sha: "in1",
               base_sha: "base",
               policy_hash: "p1"
             })
  end

  test "pass with the wrong input_sha is a sha_mismatch" do
    %{gate: gate} = running_gate!()

    assert {:error, {:sha_mismatch, _}} =
             Gates.pass(gate.id, Actor.system(), %{input_sha: "other", base_sha: "base"})
  end

  test "pass with a stale managed_run_id is a run_id_mismatch" do
    %{gate: gate} = running_gate!()

    assert {:error, {:run_id_mismatch, _}} =
             Gates.pass(gate.id, Actor.system(), %{
               input_sha: "in1",
               base_sha: "base",
               managed_run_id: "stale"
             })
  end

  test "semantic fail_retryable then a new-sha gate does not reset the ledger" do
    %{mission: mission, gate: gate} = running_gate!()

    {:ok, %{ledger: ledger}} =
      Gates.fail_retryable(gate.id, Actor.system(), %{
        finding_fingerprint: "fp-a",
        trigger_repair: true
      })

    assert ledger.total_repair_rounds == 1

    {:ok, _} =
      Gates.create(mission.id, Actor.system(), %{
        gate_type: "review",
        input_sha: "in2",
        base_sha: "base",
        policy_hash: "p1"
      })

    reloaded =
      Repo.get_by!(MissionValidationLedger, mission_id: mission.id, gate_type: "review")

    assert reloaded.total_repair_rounds == 1
    assert reloaded.id == ledger.id
  end

  test "the third identical finding is forced to failed_terminal" do
    %{mission: mission} = running_attempt!()

    Enum.each(1..3, fn i ->
      {:ok, gate} =
        Gates.create(mission.id, Actor.system(), %{
          gate_type: "review",
          input_sha: "sha-#{i}",
          base_sha: "base",
          policy_hash: "p1"
        })

      {:ok, gate} = Gates.start(gate.id, Actor.system(), %{managed_run_id: "run-#{i}"})
      {:ok, result} = Gates.fail_retryable(gate.id, Actor.system(), %{finding_fingerprint: "fp"})

      if i < 3 do
        assert result.gate.status == "failed_retryable"
      else
        assert result.gate.status == "failed_terminal"
      end
    end)

    assert Repo.aggregate(Incident, :count) == 1
  end

  test "needs_decision opens a question; a missing prompt rolls the gate back to running" do
    %{attempt: attempt, gate: gate} = running_gate!()

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
    assert Fixtures.event_types(gate.id) == ["gate.created", "gate.started"]

    {:ok, %{gate: gate, question: question}} =
      Gates.needs_decision(gate.id, Actor.system(), %{
        finding_digest: "d",
        managed_run_id: "run-1",
        question_attrs: %{
          attempt_id: attempt.id,
          request_id: "g1",
          blocking_scope: "mission",
          requested_authority: "boss",
          prompt: "waiver?",
          subject_type: "gate",
          subject_id: gate.id
        }
      })

    assert gate.status == "needs_decision"
    assert question.status == "open"
    assert question.subject_type == "gate"
    assert question.subject_id == gate.id
    assert length(open_validation(gate)) == 1
    assert length(open_blockers(gate.mission_id)) == 1
  end

  test "answer alone does not close the validation blocker or mark the gate runnable" do
    %{gate: gate, attempt: attempt} = running_gate!()
    %{gate: gate, question: question} = ask!(gate, attempt)

    {:ok, question} = Questions.answer(question.id, Actor.boss(), %{answer: "waive"})
    grant!(gate, question)

    gate = Repo.get!(Gate, gate.id)
    assert gate.status == "needs_decision"
    assert question.status == "answered"
    assert length(open_validation(gate)) == 1
    assert length(open_blockers(gate.mission_id)) == 1
  end

  test "rerun_after_decision after answer closes the validation blocker and sets pending" do
    %{gate: gate, attempt: attempt} = running_gate!()
    %{gate: gate, question: question} = ask!(gate, attempt)
    {:ok, question} = Questions.answer(question.id, Actor.boss(), %{answer: "waive"})
    decision = grant!(gate, question)

    {:ok, gate} = Gates.rerun_after_decision(gate.id, Actor.system(), decision.id)
    assert gate.status == "pending"
    assert open_validation(gate) == []
    assert open_blockers(gate.mission_id) == []
  end

  test "duplicate needs_decision while the question is open reuses it and the blocker" do
    %{gate: gate, attempt: attempt} = running_gate!()
    %{gate: gate, question: first} = ask!(gate, attempt)
    %{gate: gate, question: second} = ask!(gate, attempt)

    assert first.id == second.id
    assert gate.status == "needs_decision"
    assert Repo.aggregate(Question, :count) == 1
    assert length(open_validation(gate)) == 1
    assert length(open_blockers(gate.mission_id)) == 1
  end

  test "the same approved fingerprint on a later run is an incident, not a reused question" do
    %{gate: gate, attempt: attempt} = running_gate!()
    %{gate: gate, question: question} = ask!(gate, attempt)
    {:ok, question} = Questions.answer(question.id, Actor.boss(), %{answer: "waive"})
    decision = grant!(gate, question)
    {:ok, gate} = Gates.rerun_after_decision(gate.id, Actor.system(), decision.id)
    {:ok, gate} = Gates.start(gate.id, Actor.system(), %{managed_run_id: "run-2"})

    {:ok, result} =
      Gates.needs_decision(gate.id, Actor.system(), %{
        finding_digest: "fp-a",
        managed_run_id: "run-2",
        question_attrs: %{
          attempt_id: attempt.id,
          request_id: "g1",
          blocking_scope: "mission",
          requested_authority: "boss",
          prompt: "waiver?"
        }
      })

    assert result.gate.status == "failed_terminal"
    assert Repo.get!(Question, question.id).status == "answered"
    assert Repo.aggregate(Question, :count) == 1
    assert Repo.aggregate(Incident, :count) == 1
  end

  test "a different fingerprint after rerun opens a new question" do
    %{gate: gate, attempt: attempt} = running_gate!()
    %{gate: gate, question: first} = ask!(gate, attempt)
    {:ok, first} = Questions.answer(first.id, Actor.boss(), %{answer: "waive"})
    decision = grant!(gate, first)
    {:ok, gate} = Gates.rerun_after_decision(gate.id, Actor.system(), decision.id)
    {:ok, gate} = Gates.start(gate.id, Actor.system(), %{managed_run_id: "run-2"})

    %{gate: gate, question: second} =
      ask!(gate, attempt, %{finding_digest: "fp-b", managed_run_id: "run-2"})

    assert second.id != first.id
    assert second.status == "open"
    assert Repo.aggregate(Question, :count) == 2
    assert length(open_validation(gate)) == 1
    assert length(open_blockers(gate.mission_id)) == 1
  end

  test "rerun_after_decision refuses a decision bound to a different sha pair" do
    %{gate: gate, attempt: attempt} = running_gate!()
    %{gate: gate, question: question} = ask!(gate, attempt)
    {:ok, question} = Questions.answer(question.id, Actor.boss(), %{answer: "waive"})
    decision = grant!(gate, question, %{input_sha: "other"})

    assert {:error, {:sha_mismatch, _}} =
             Gates.rerun_after_decision(gate.id, Actor.system(), decision.id)

    assert Repo.get!(Gate, gate.id).status == "needs_decision"
    assert length(open_validation(gate)) == 1
  end

  test "rerun_after_decision refuses a decision from another gate with the same SHAs" do
    %{gate: gate_a, attempt: attempt_a} = running_gate!(%{input_sha: "shared"})
    %{gate: gate_a, question: question_a} = ask!(gate_a, attempt_a)
    {:ok, question_a} = Questions.answer(question_a.id, Actor.boss(), %{answer: "waive"})
    _decision_a = grant!(gate_a, question_a)

    %{gate: gate_b, attempt: attempt_b} = running_gate!(%{input_sha: "shared"})
    %{question: question_b} = ask!(gate_b, attempt_b)
    {:ok, question_b} = Questions.answer(question_b.id, Actor.boss(), %{answer: "waive"})
    foreign = grant!(gate_b, question_b)

    assert {:error, {:illegal_transition, %{reason: :decision_wrong_mission}}} =
             Gates.rerun_after_decision(gate_a.id, Actor.system(), foreign.id)

    assert Repo.get!(Gate, gate_a.id).status == "needs_decision"
    assert length(open_validation(gate_a)) == 1
  end

  test "rerun_after_decision refuses a decision bound to another gate on the same mission" do
    %{mission: mission, attempt: attempt, gate: review} = running_gate!()
    %{gate: review, question: question} = ask!(review, attempt)
    {:ok, question} = Questions.answer(question.id, Actor.boss(), %{answer: "waive"})
    _own = grant!(review, question)

    {:ok, lint} =
      Gates.create(mission.id, Actor.system(), %{
        gate_type: "lint",
        input_sha: "in1",
        base_sha: "base",
        policy_hash: "p1"
      })

    {:ok, lint} = Gates.start(lint.id, Actor.system(), %{managed_run_id: "run-lint"})
    %{question: other} = ask!(lint, attempt, %{managed_run_id: "run-lint"})
    {:ok, other} = Questions.answer(other.id, Actor.boss(), %{answer: "waive"})
    foreign = grant!(lint, other)

    assert {:error, {:illegal_transition, %{reason: :decision_wrong_gate}}} =
             Gates.rerun_after_decision(review.id, Actor.system(), foreign.id)

    assert Repo.get!(Gate, review.id).status == "needs_decision"
  end

  test "rerun_after_decision refuses expired or revoked decisions" do
    %{gate: gate, attempt: attempt} = running_gate!()
    %{gate: gate, question: question} = ask!(gate, attempt)
    {:ok, question} = Questions.answer(question.id, Actor.boss(), %{answer: "waive"})

    expired =
      grant!(gate, question, %{expires_at: DateTime.add(DateTime.utc_now(), -60, :second)})

    assert {:error, {:illegal_transition, %{reason: :decision_expired}}} =
             Gates.rerun_after_decision(gate.id, Actor.system(), expired.id)

    {:ok, _} = Repo.delete(expired)
    revoked = grant!(gate, question, %{revoked_at: DateTime.utc_now()})

    assert {:error, {:illegal_transition, %{reason: :decision_revoked}}} =
             Gates.rerun_after_decision(gate.id, Actor.system(), revoked.id)

    assert Repo.get!(Gate, gate.id).status == "needs_decision"
    assert length(open_validation(gate)) == 1
  end

  test "cancel from needs_decision closes the validation blocker and withdraws the question" do
    %{gate: gate, attempt: attempt} = running_gate!()
    %{gate: gate, question: question} = ask!(gate, attempt)

    {:ok, gate} = Gates.cancel(gate.id, Actor.system())
    assert gate.status == "canceled"
    assert open_validation(gate) == []
    assert open_blockers(gate.mission_id) == []
    assert Repo.get!(Question, question.id).status == "withdrawn"
  end

  test "pass and fail_terminal leave no stale needs_decision blocker" do
    %{gate: passing} = running_gate!(%{input_sha: "pass-sha"})

    {:ok, passing} =
      Gates.pass(passing.id, Actor.system(), %{
        input_sha: "pass-sha",
        base_sha: "base",
        managed_run_id: "run-1"
      })

    assert passing.status == "passed"
    assert open_validation(passing) == []

    %{gate: failing} = running_gate!(%{input_sha: "fail-sha"})
    {:ok, result} = Gates.fail_terminal(failing.id, Actor.system(), %{reason: "terminal"})
    assert result.gate.status == "failed_terminal"
    blockers = open_validation(result.gate)
    assert length(blockers) == 1
    assert hd(blockers).reason == "terminal"
  end

  test "infrastructure retry may return the same row to pending; semantic failed_retryable may not" do
    %{gate: semantic} = running_gate!(%{input_sha: "sem"})
    {:ok, _} = Gates.fail_retryable(semantic.id, Actor.system(), %{finding_fingerprint: "fp"})

    assert {:error, {:illegal_transition, %{reason: :not_infrastructure}}} =
             Gates.retry_infrastructure(semantic.id, Actor.system())

    %{gate: infra} = running_gate!(%{input_sha: "inf"})
    {:ok, infra} = Gates.record_infrastructure_error(infra.id, Actor.system())
    {:ok, infra} = Gates.retry_infrastructure(infra.id, Actor.system())
    assert infra.status == "pending"
  end
end
