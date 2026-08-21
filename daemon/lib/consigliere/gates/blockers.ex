defmodule Consigliere.Gates.Blockers do
  @moduledoc false

  import Ecto.Query

  alias Consigliere.Repo
  alias Consigliere.Txn
  alias Consigliere.Gates.Gate
  alias Consigliere.MissionBlockers.MissionBlocker
  alias Consigliere.Questions.Question
  alias Consigliere.Questions.Transitions, as: Questions
  alias Consigliere.Decisions.Decision
  alias Consigliere.DomainEvents.DomainEvent
  alias Consigliere.Incidents.Incident

  def bind_question_attrs(gate, attrs) do
    question_attrs = Map.fetch!(attrs, :question_attrs)
    fingerprint = Map.get(attrs, :finding_digest)

    request_id =
      if is_binary(fingerprint) and fingerprint != "" do
        gate.id <> ":" <> fingerprint
      else
        Map.fetch!(question_attrs, :request_id)
      end

    question_attrs
    |> Map.put(:request_id, request_id)
    |> Map.put(:subject_type, "gate")
    |> Map.put(:subject_id, gate.id)
  end

  def existing_question(question_attrs) do
    Repo.get_by(Question,
      attempt_id: Map.fetch!(question_attrs, :attempt_id),
      request_id: Map.fetch!(question_attrs, :request_id)
    )
  end

  def open_gate_question(gate) do
    Repo.one(
      from(q in Question,
        where:
          q.subject_type == "gate" and q.subject_id == ^gate.id and q.status in ["open", "routed"],
        order_by: [desc: q.inserted_at],
        limit: 1
      )
    )
  end

  def openish?(%Question{status: status}) when status in ~w(open routed), do: true
  def openish?(_), do: false

  def open_validation!(gate, reason) do
    case Repo.one(validation_scope(gate)) do
      nil -> insert_validation!(gate, reason)
      blocker -> blocker
    end
  end

  def close_validation!(gate, reason) do
    validation_scope(gate) |> Repo.all() |> Enum.each(&close_blocker!(&1, reason))
  end

  def withdraw_open_questions!(gate, actor, reason \\ "gate_canceled") do
    from(q in Question,
      where:
        q.subject_type == "gate" and q.subject_id == ^gate.id and q.status in ["open", "routed"]
    )
    |> Repo.all()
    |> Enum.each(fn question ->
      Questions.withdraw_txn(question.id, actor, reason)
    end)
  end

  def verify_decision!(gate, decision) do
    if decision.mission_id && decision.mission_id != gate.mission_id do
      Txn.illegal(gate.status, "pending", :decision_wrong_mission)
    end

    unless decision.question_id do
      Txn.illegal(gate.status, "pending", :decision_unbound)
    end

    if decision.revoked_at, do: Txn.illegal(gate.status, "pending", :decision_revoked)

    if expired?(decision), do: Txn.illegal(gate.status, "pending", :decision_expired)

    question =
      case Repo.get(Question, decision.question_id) do
        nil -> Txn.illegal(gate.status, "pending", :question_not_found)
        q -> q
      end

    unless question.subject_type == "gate" and question.subject_id == gate.id do
      Txn.illegal(gate.status, "pending", :decision_wrong_gate)
    end

    unless question.status == "answered" do
      Txn.illegal(gate.status, "pending", :question_not_answered)
    end

    unless fingerprint_bound?(question, gate) do
      Txn.illegal(gate.status, "pending", :fingerprint_mismatch)
    end

    unless decision.input_sha == gate.input_sha and decision.base_sha == gate.base_sha do
      Txn.sha_mismatch({gate.input_sha, gate.base_sha}, {decision.input_sha, decision.base_sha})
    end

    unless is_binary(decision.policy_hash) and decision.policy_hash == gate.policy_hash do
      Txn.illegal(gate.status, "pending", :policy_hash_mismatch)
    end

    if is_binary(decision.finding_fingerprint) and decision.finding_fingerprint != "" and
         decision.finding_fingerprint != gate.finding_digest do
      Txn.illegal(gate.status, "pending", :fingerprint_mismatch)
    end

    if uses_exhausted?(gate, decision) do
      Txn.illegal(gate.status, "pending", :decision_uses_exhausted)
    end

    {decision, question}
  end

  def fetch_decision!(gate, decision_id) do
    case Repo.get(Decision, decision_id) do
      nil -> Txn.illegal(gate.status, "pending", :decision_not_found)
      decision -> decision
    end
  end

  def decide_needs_decision(gate, actor, attrs) do
    question_attrs = bind_question_attrs(gate, attrs)
    existing = existing_question(question_attrs)

    cond do
      gate.status == "needs_decision" and openish?(existing) ->
        open_validation!(gate, "gate needs decision")
        %{gate: gate, question: existing}

      gate.status == "needs_decision" ->
        open_validation!(gate, "gate needs decision")
        %{gate: gate, question: open_gate_question(gate) || existing}

      gate.status != "running" ->
        Txn.illegal(gate.status, "needs_decision", :wrong_status)

      existing && not openish?(existing) ->
        fail_terminal!(gate, actor, "repeated needs_decision after approval")

      true ->
        open_needs_decision!(gate, actor, attrs, question_attrs)
    end
  end

  def fail_terminal!(gate, actor, reason) do
    withdraw_open_questions!(gate, actor, "gate_failed_terminal")
    close_validation!(gate, "failed_terminal")

    Txn.insert!(
      Incident.changeset(%Incident{}, %{
        mission_id: gate.mission_id,
        subject_type: "gate",
        subject_id: gate.id,
        severity: "terminal",
        reason: reason
      })
    )

    insert_validation!(gate, reason)
    gate = Txn.update!(Gate.changeset(gate, %{status: "failed_terminal"}))
    Txn.append_event!("gate.failed_terminal", "gate", gate.id, %{reason: reason})
    %{gate: gate}
  end

  defp open_needs_decision!(gate, actor, attrs, question_attrs) do
    question = Questions.open_txn(question_attrs, actor)
    open_validation!(gate, "gate needs decision")

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

  defp validation_scope(gate) do
    from(b in MissionBlocker,
      where:
        b.mission_id == ^gate.mission_id and b.kind == "validation" and b.status == "open" and
          b.subject_type == "gate" and b.subject_id == ^gate.id
    )
  end

  defp insert_validation!(gate, reason) do
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
  end

  defp close_blocker!(blocker, reason) do
    Txn.update!(
      MissionBlocker.changeset(blocker, %{
        status: "closed",
        closed_reason: reason,
        closed_at: Txn.now()
      })
    )
  end

  defp expired?(%{expires_at: nil}), do: false

  defp expired?(%{expires_at: expires_at}) do
    DateTime.compare(expires_at, Txn.now()) == :lt
  end

  defp fingerprint_bound?(question, gate) do
    digest = gate.finding_digest

    cond do
      not is_binary(digest) or digest == "" -> true
      String.ends_with?(question.request_id, ":" <> digest) -> true
      question.request_id == digest -> true
      true -> false
    end
  end

  defp uses_exhausted?(_gate, %{maximum_uses: uses}) when not is_integer(uses), do: false

  defp uses_exhausted?(gate, decision) do
    count =
      from(e in DomainEvent,
        where: e.type == "gate.rerun_after_decision" and e.subject_id == ^gate.id
      )
      |> Repo.all()
      |> Enum.count(fn event ->
        event.payload["decision_id"] == decision.id or event.payload[:decision_id] == decision.id
      end)

    count >= decision.maximum_uses
  end
end
