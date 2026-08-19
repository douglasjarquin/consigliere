defmodule Consigliere.Gates.TransitionsTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Fixtures
  alias Consigliere.Missions
  alias Consigliere.Attempts
  alias Consigliere.Gates
  alias Consigliere.Repo
  alias Consigliere.Gates.Gate
  alias Consigliere.MissionValidationLedgers.MissionValidationLedger
  alias Consigliere.Incidents.Incident
  alias Consigliere.Decisions.Decision

  setup do
    Fixtures.reset_phase1_tables!()
    :ok
  end

  defp running_attempt! do
    {:ok, mission} =
      Missions.create(%{objective: "o", scope: "s", acceptance_criteria: "a"}, Actor.boss())

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Missions.grant_work_authorization(mission.id, Actor.boss())

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

  test "duplicate identity is rejected until the first gate is invalidated" do
    %{mission: mission, gate: gate} = running_gate!()
    {:ok, gate} = Gates.pass(gate.id, Actor.system(), %{input_sha: "in1", base_sha: "base", managed_run_id: "run-1"})

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
  end

  test "rerun_after_decision refuses a decision bound to a different sha pair" do
    %{gate: gate, attempt: attempt} = running_gate!()

    {:ok, %{gate: gate}} =
      Gates.needs_decision(gate.id, Actor.system(), %{
        finding_digest: "d",
        managed_run_id: "run-1",
        question_attrs: %{
          attempt_id: attempt.id,
          request_id: "g1",
          blocking_scope: "mission",
          requested_authority: "boss",
          prompt: "waiver?"
        }
      })

    {:ok, decision} =
      Repo.insert(
        Decision.changeset(%Decision{}, %{
          mission_id: gate.mission_id,
          scope: "sha_bound",
          granted_by_principal: "boss",
          input_sha: "other",
          base_sha: "base"
        })
      )

    assert {:error, {:sha_mismatch, _}} =
             Gates.rerun_after_decision(gate.id, Actor.system(), decision.id)

    assert Repo.get!(Gate, gate.id).status == "needs_decision"
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
