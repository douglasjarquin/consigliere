defmodule Consigliere.Gates.Transitions do
  @moduledoc false

  alias Consigliere.DatabaseWriter
  alias Consigliere.Txn
  alias Consigliere.Gates.Gate
  alias Consigliere.Gates.Blockers
  alias Consigliere.Gates.Support
  alias Consigliere.MissionValidationLedgers.MissionValidationLedger

  @default_identical_finding_limit 2
  @default_repair_round_limit 3

  def create(mission_id, actor, attrs) do
    DatabaseWriter.transaction(fn -> create_txn(mission_id, actor, attrs) end)
  end

  def create_txn(mission_id, actor, attrs) do
    Txn.require_principal(actor, ["daemon", "boss"])
    _mission = Support.fetch_mission!(mission_id)

    gate =
      Txn.insert!(
        Gate.changeset(%Gate{}, %{
          mission_id: mission_id,
          gate_type: Map.fetch!(attrs, :gate_type),
          input_sha: Map.fetch!(attrs, :input_sha),
          base_sha: Map.fetch!(attrs, :base_sha),
          policy_hash: Map.fetch!(attrs, :policy_hash),
          status: "pending"
        })
      )

    Txn.append_event!("gate.created", "gate", gate.id)
    gate
  end

  def start(gate_id, actor, attrs) do
    DatabaseWriter.transaction(fn -> start_txn(gate_id, actor, attrs) end)
  end

  def start_txn(gate_id, actor, attrs) do
    Txn.require_principal(actor, ["daemon"])
    gate = Support.fetch_gate!(gate_id)
    Support.require_status!(gate, "pending", "running")

    gate =
      Txn.update!(
        Gate.changeset(gate, %{
          status: "running",
          managed_run_id: Map.fetch!(attrs, :managed_run_id)
        })
      )

    Txn.append_event!("gate.started", "gate", gate.id)
    gate
  end

  def pass(gate_id, actor, attrs) do
    DatabaseWriter.transaction(fn -> pass_txn(gate_id, actor, attrs) end)
  end

  def pass_txn(gate_id, actor, attrs) do
    Txn.require_principal(actor, ["daemon"])
    gate = Support.fetch_gate!(gate_id)
    Support.require_status!(gate, "running", "passed")
    Support.match_identity!(gate, attrs)
    Support.match_run_id!(gate, attrs)
    Blockers.close_validation!(gate, "passed")

    gate =
      Txn.update!(
        Gate.changeset(gate, %{status: "passed", output_sha: Map.get(attrs, :output_sha)})
      )

    Txn.append_event!("gate.passed", "gate", gate.id)
    gate
  end

  def needs_decision(gate_id, actor, attrs) do
    DatabaseWriter.transaction(fn -> needs_decision_txn(gate_id, actor, attrs) end)
  end

  def needs_decision_txn(gate_id, actor, attrs) do
    Txn.require_principal(actor, ["daemon"])
    gate = Support.fetch_gate!(gate_id)
    Support.match_run_id!(gate, attrs)
    Blockers.decide_needs_decision(gate, actor, attrs)
  end

  def fail_retryable(gate_id, actor, attrs) do
    DatabaseWriter.transaction(fn -> fail_retryable_txn(gate_id, actor, attrs) end)
  end

  def fail_retryable_txn(gate_id, actor, attrs) do
    Txn.require_principal(actor, ["daemon"])
    gate = Support.fetch_gate!(gate_id)
    Support.require_status!(gate, "running", "failed_retryable")
    mission = Support.fetch_mission!(gate.mission_id)
    ledger = Support.load_or_create_ledger!(gate)
    fingerprint = Map.get(attrs, :finding_fingerprint)
    trigger_repair = Map.get(attrs, :trigger_repair, true)

    {counts, fingerprint_count} =
      Support.bump_fingerprint(ledger.identical_finding_counts_json || %{}, fingerprint)

    repair_rounds =
      if trigger_repair, do: ledger.total_repair_rounds + 1, else: ledger.total_repair_rounds

    identical_limit =
      Support.policy_int(
        mission,
        gate.gate_type,
        "identical_finding_limit",
        @default_identical_finding_limit
      )

    repair_limit =
      Support.policy_int(
        mission,
        gate.gate_type,
        "repair_round_limit",
        @default_repair_round_limit
      )

    ledger =
      Txn.update!(
        MissionValidationLedger.changeset(ledger, %{
          total_failed_runs: ledger.total_failed_runs + 1,
          total_repair_rounds: repair_rounds,
          identical_finding_counts_json: counts
        })
      )

    if fingerprint_count > identical_limit or repair_rounds > repair_limit do
      Blockers.fail_terminal!(gate, actor, "repair budget exceeded")
    else
      Blockers.close_validation!(gate, "failed_retryable")
      gate = Txn.update!(Gate.changeset(gate, %{status: "failed_retryable"}))
      Txn.append_event!("gate.failed_retryable", "gate", gate.id)
      %{gate: gate, ledger: ledger}
    end
  end

  def fail_terminal(gate_id, actor, attrs) do
    DatabaseWriter.transaction(fn -> fail_terminal_txn(gate_id, actor, attrs) end)
  end

  def fail_terminal_txn(gate_id, actor, attrs) do
    Txn.require_principal(actor, ["daemon", "boss"])
    gate = Support.fetch_gate!(gate_id)
    Support.require_status!(gate, "running", "failed_terminal")
    Blockers.fail_terminal!(gate, actor, Map.get(attrs, :reason, "terminal"))
  end

  def record_infrastructure_error(gate_id, actor) do
    DatabaseWriter.transaction(fn -> record_infrastructure_error_txn(gate_id, actor) end)
  end

  def record_infrastructure_error_txn(gate_id, actor) do
    Txn.require_principal(actor, ["daemon"])
    gate = Support.fetch_gate!(gate_id)
    Support.require_status!(gate, "running", "failed_retryable")
    ledger = Support.load_or_create_ledger!(gate)

    Txn.update!(
      MissionValidationLedger.changeset(ledger, %{
        total_infrastructure_retries: ledger.total_infrastructure_retries + 1
      })
    )

    Blockers.close_validation!(gate, "infrastructure_retry")
    gate = Txn.update!(Gate.changeset(gate, %{status: "failed_retryable"}))
    Txn.append_event!("gate.infrastructure_retry", "gate", gate.id, %{kind: "infrastructure"})
    gate
  end

  def retry_infrastructure(gate_id, actor) do
    DatabaseWriter.transaction(fn -> retry_infrastructure_txn(gate_id, actor) end)
  end

  def retry_infrastructure_txn(gate_id, actor) do
    Txn.require_principal(actor, ["daemon"])
    gate = Support.fetch_gate!(gate_id)
    Support.require_status!(gate, "failed_retryable", "pending")
    last = Support.last_event(gate)

    unless last && last.type == "gate.infrastructure_retry" do
      Txn.illegal(gate.status, "pending", :not_infrastructure)
    end

    Blockers.close_validation!(gate, "infrastructure_retry")
    Txn.update!(Gate.changeset(gate, %{status: "pending", managed_run_id: nil}))
  end

  def rerun_after_decision(gate_id, actor, decision_id) do
    DatabaseWriter.transaction(fn -> rerun_after_decision_txn(gate_id, actor, decision_id) end)
  end

  def rerun_after_decision_txn(gate_id, actor, decision_id) do
    Txn.require_principal(actor, ["daemon", "boss"])
    gate = Support.fetch_gate!(gate_id)
    Support.require_status!(gate, "needs_decision", "pending")
    decision = Blockers.fetch_decision!(gate, decision_id)
    Blockers.verify_decision!(gate, decision)
    Blockers.close_validation!(gate, "rerun_after_decision")
    gate = Txn.update!(Gate.changeset(gate, %{status: "pending", managed_run_id: nil}))
    Txn.append_event!("gate.rerun_after_decision", "gate", gate.id, %{decision_id: decision.id})
    gate
  end

  def cancel(gate_id, actor) do
    DatabaseWriter.transaction(fn -> cancel_txn(gate_id, actor) end)
  end

  def cancel_txn(gate_id, actor) do
    Txn.require_principal(actor, ["daemon", "boss"])
    gate = Support.fetch_gate!(gate_id)

    unless gate.status in ["pending", "running", "needs_decision"] do
      Txn.illegal(gate.status, "canceled", :wrong_status)
    end

    Blockers.withdraw_open_questions!(gate, actor)
    Blockers.close_validation!(gate, "canceled")
    gate = Txn.update!(Gate.changeset(gate, %{status: "canceled"}))
    Txn.append_event!("gate.canceled", "gate", gate.id)
    gate
  end

  def invalidate(gate_id, actor) do
    DatabaseWriter.transaction(fn -> invalidate_txn(gate_id, actor) end)
  end

  def invalidate_txn(gate_id, actor) do
    Txn.require_principal(actor, ["daemon", "boss"])
    gate = Support.fetch_gate!(gate_id)
    Support.require_status!(gate, "passed", "invalidated")
    Blockers.close_validation!(gate, "invalidated")
    gate = Txn.update!(Gate.changeset(gate, %{status: "invalidated"}))
    Txn.append_event!("gate.invalidated", "gate", gate.id)
    gate
  end
end
