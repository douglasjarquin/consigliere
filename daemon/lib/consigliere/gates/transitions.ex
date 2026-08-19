defmodule Consigliere.Gates.Transitions do
  @moduledoc false

  import Ecto.Query

  alias Consigliere.DatabaseWriter
  alias Consigliere.Repo
  alias Consigliere.Txn
  alias Consigliere.Gates.Gate
  alias Consigliere.Missions.Mission
  alias Consigliere.Questions.Transitions, as: Questions
  alias Consigliere.MissionBlockers.MissionBlocker
  alias Consigliere.MissionValidationLedgers.MissionValidationLedger
  alias Consigliere.Incidents.Incident
  alias Consigliere.Decisions.Decision
  alias Consigliere.DomainEvents.DomainEvent

  @default_identical_finding_limit 2
  @default_repair_round_limit 3

  def create(mission_id, actor, attrs) do
    DatabaseWriter.transaction(fn -> create_txn(mission_id, actor, attrs) end)
  end

  def create_txn(mission_id, actor, attrs) do
    Txn.require_principal(actor, ["daemon", "boss"])
    _mission = fetch_mission!(mission_id)

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
    gate = fetch!(gate_id)
    require_status!(gate, "pending", "running")

    gate =
      Txn.update!(
        Gate.changeset(gate, %{status: "running", managed_run_id: Map.fetch!(attrs, :managed_run_id)})
      )

    Txn.append_event!("gate.started", "gate", gate.id)
    gate
  end

  def pass(gate_id, actor, attrs) do
    DatabaseWriter.transaction(fn -> pass_txn(gate_id, actor, attrs) end)
  end

  def pass_txn(gate_id, actor, attrs) do
    Txn.require_principal(actor, ["daemon"])
    gate = fetch!(gate_id)
    require_status!(gate, "running", "passed")
    match_identity!(gate, attrs)
    match_run_id!(gate, attrs)

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
    gate = fetch!(gate_id)
    require_status!(gate, "running", "needs_decision")
    match_run_id!(gate, attrs)

    question_attrs = Map.fetch!(attrs, :question_attrs)
    question = Questions.open_txn(question_attrs, actor)

    Txn.insert!(
      MissionBlocker.changeset(%MissionBlocker{}, %{
        mission_id: gate.mission_id,
        kind: "validation",
        reason: "gate needs decision",
        status: "open",
        subject_type: "gate",
        subject_id: gate.id
      })
    )

    gate =
      Txn.update!(
        Gate.changeset(gate, %{
          status: "needs_decision",
          finding_digest: Map.get(attrs, :finding_digest)
        })
      )

    Txn.append_event!("gate.needs_decision", "gate", gate.id, %{question_id: question.id})
    %{gate: gate, question: question}
  end

  def fail_retryable(gate_id, actor, attrs) do
    DatabaseWriter.transaction(fn -> fail_retryable_txn(gate_id, actor, attrs) end)
  end

  def fail_retryable_txn(gate_id, actor, attrs) do
    Txn.require_principal(actor, ["daemon"])
    gate = fetch!(gate_id)
    require_status!(gate, "running", "failed_retryable")
    mission = fetch_mission!(gate.mission_id)
    ledger = load_or_create_ledger!(gate)
    fingerprint = Map.get(attrs, :finding_fingerprint)
    trigger_repair = Map.get(attrs, :trigger_repair, true)

    counts = ledger.identical_finding_counts_json || %{}

    {counts, fingerprint_count} =
      if is_binary(fingerprint) do
        next = Map.update(counts, fingerprint, 1, &(&1 + 1))
        {next, Map.fetch!(next, fingerprint)}
      else
        {counts, 0}
      end

    repair_rounds =
      if trigger_repair, do: ledger.total_repair_rounds + 1, else: ledger.total_repair_rounds

    identical_limit = policy_int(mission, gate.gate_type, "identical_finding_limit", @default_identical_finding_limit)
    repair_limit = policy_int(mission, gate.gate_type, "repair_round_limit", @default_repair_round_limit)

    over_limit = fingerprint_count > identical_limit or repair_rounds > repair_limit

    ledger =
      Txn.update!(
        MissionValidationLedger.changeset(ledger, %{
          total_failed_runs: ledger.total_failed_runs + 1,
          total_repair_rounds: repair_rounds,
          identical_finding_counts_json: counts
        })
      )

    if over_limit do
      fail_terminal_from_running!(gate, "repair budget exceeded")
    else
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
    gate = fetch!(gate_id)
    require_status!(gate, "running", "failed_terminal")
    fail_terminal_from_running!(gate, Map.get(attrs, :reason, "terminal"))
  end

  def record_infrastructure_error(gate_id, actor) do
    DatabaseWriter.transaction(fn -> record_infrastructure_error_txn(gate_id, actor) end)
  end

  def record_infrastructure_error_txn(gate_id, actor) do
    Txn.require_principal(actor, ["daemon"])
    gate = fetch!(gate_id)
    require_status!(gate, "running", "failed_retryable")
    ledger = load_or_create_ledger!(gate)

    Txn.update!(
      MissionValidationLedger.changeset(ledger, %{
        total_infrastructure_retries: ledger.total_infrastructure_retries + 1
      })
    )

    gate = Txn.update!(Gate.changeset(gate, %{status: "failed_retryable"}))
    Txn.append_event!("gate.infrastructure_retry", "gate", gate.id, %{kind: "infrastructure"})
    gate
  end

  def retry_infrastructure(gate_id, actor) do
    DatabaseWriter.transaction(fn -> retry_infrastructure_txn(gate_id, actor) end)
  end

  def retry_infrastructure_txn(gate_id, actor) do
    Txn.require_principal(actor, ["daemon"])
    gate = fetch!(gate_id)
    require_status!(gate, "failed_retryable", "pending")

    last =
      Repo.one(
        from e in DomainEvent,
          where: e.subject_id == ^gate.id,
          order_by: [desc: e.id],
          limit: 1
      )

    unless last && last.type == "gate.infrastructure_retry" do
      Txn.illegal(gate.status, "pending", :not_infrastructure)
    end

    gate = Txn.update!(Gate.changeset(gate, %{status: "pending", managed_run_id: nil}))
    gate
  end

  def rerun_after_decision(gate_id, actor, decision_id) do
    DatabaseWriter.transaction(fn -> rerun_after_decision_txn(gate_id, actor, decision_id) end)
  end

  def rerun_after_decision_txn(gate_id, actor, decision_id) do
    Txn.require_principal(actor, ["daemon", "boss"])
    gate = fetch!(gate_id)
    require_status!(gate, "needs_decision", "pending")

    decision =
      case Repo.get(Decision, decision_id) do
        nil -> Txn.illegal(gate.status, "pending", :decision_not_found)
        d -> d
      end

    sha_ok =
      (decision.input_sha == gate.input_sha and decision.base_sha == gate.base_sha) or
        (decision.scope == "sha_bound" and decision.input_sha == gate.input_sha and
           decision.base_sha == gate.base_sha)

    unless sha_ok do
      Txn.sha_mismatch({gate.input_sha, gate.base_sha}, {decision.input_sha, decision.base_sha})
    end

    gate = Txn.update!(Gate.changeset(gate, %{status: "pending", managed_run_id: nil}))
    Txn.append_event!("gate.rerun_after_decision", "gate", gate.id, %{decision_id: decision.id})
    gate
  end

  def cancel(gate_id, actor) do
    DatabaseWriter.transaction(fn -> cancel_txn(gate_id, actor) end)
  end

  def cancel_txn(gate_id, actor) do
    Txn.require_principal(actor, ["daemon", "boss"])
    gate = fetch!(gate_id)

    unless gate.status in ["pending", "running"] do
      Txn.illegal(gate.status, "canceled", :wrong_status)
    end

    gate = Txn.update!(Gate.changeset(gate, %{status: "canceled"}))
    Txn.append_event!("gate.canceled", "gate", gate.id)
    gate
  end

  def invalidate(gate_id, actor) do
    DatabaseWriter.transaction(fn -> invalidate_txn(gate_id, actor) end)
  end

  def invalidate_txn(gate_id, actor) do
    Txn.require_principal(actor, ["daemon", "boss"])
    gate = fetch!(gate_id)
    require_status!(gate, "passed", "invalidated")
    gate = Txn.update!(Gate.changeset(gate, %{status: "invalidated"}))
    Txn.append_event!("gate.invalidated", "gate", gate.id)
    gate
  end

  defp fetch!(id) do
    case Repo.get(Gate, id) do
      nil -> Txn.illegal(nil, nil, :not_found)
      gate -> gate
    end
  end

  defp fetch_mission!(id) do
    case Repo.get(Mission, id) do
      nil -> Txn.illegal(nil, nil, :not_found)
      mission -> mission
    end
  end

  defp require_status!(gate, from, to) do
    if gate.status == from, do: :ok, else: Txn.illegal(gate.status, to, :wrong_status)
  end

  defp match_identity!(gate, attrs) do
    input = Map.get(attrs, :input_sha, gate.input_sha)
    base = Map.get(attrs, :base_sha, gate.base_sha)

    if input != gate.input_sha or base != gate.base_sha do
      Txn.sha_mismatch({gate.input_sha, gate.base_sha}, {input, base})
    end
  end

  defp match_run_id!(gate, attrs) do
    got = Map.get(attrs, :managed_run_id)

    if got && gate.managed_run_id && got != gate.managed_run_id do
      Txn.run_id_mismatch(gate.managed_run_id, got)
    end
  end

  defp load_or_create_ledger!(gate) do
    case Repo.get_by(MissionValidationLedger,
           mission_id: gate.mission_id,
           gate_type: gate.gate_type
         ) do
      nil ->
        Txn.insert!(
          MissionValidationLedger.changeset(%MissionValidationLedger{}, %{
            mission_id: gate.mission_id,
            gate_type: gate.gate_type
          })
        )

      ledger ->
        ledger
    end
  end

  defp policy_int(mission, gate_type, key, default) do
    case get_in(mission.validation_policy, [gate_type, key]) do
      n when is_integer(n) -> n
      _ -> default
    end
  end

  defp fail_terminal_from_running!(gate, reason) do
    Txn.insert!(
      Incident.changeset(%Incident{}, %{
        mission_id: gate.mission_id,
        subject_type: "gate",
        subject_id: gate.id,
        severity: "terminal",
        reason: reason
      })
    )

    Txn.insert!(
      MissionBlocker.changeset(%MissionBlocker{}, %{
        mission_id: gate.mission_id,
        kind: "validation",
        reason: reason,
        status: "open",
        subject_type: "gate",
        subject_id: gate.id
      })
    )

    gate = Txn.update!(Gate.changeset(gate, %{status: "failed_terminal"}))
    Txn.append_event!("gate.failed_terminal", "gate", gate.id, %{reason: reason})
    %{gate: gate}
  end
end
