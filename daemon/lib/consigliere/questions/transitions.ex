defmodule Consigliere.Questions.Transitions do
  @moduledoc false

  import Ecto.Query

  alias Consigliere.DatabaseWriter
  alias Consigliere.Repo
  alias Consigliere.Txn
  alias Consigliere.Questions.Question
  alias Consigliere.Attempts.Attempt
  alias Consigliere.MissionBlockers.MissionBlocker
  alias Consigliere.Incidents.Incident
  alias Consigliere.OutboxItems.OutboxItem
  alias Consigliere.Capabilities

  @openish ~w(open routed)
  @attempt_terminal ~w(completed failed lost canceled superseded)

  def open(attrs, actor) do
    DatabaseWriter.transaction(fn -> open_txn(attrs, actor) end)
  end

  def open_txn(attrs, actor) do
    attempt = fetch_attempt!(Map.fetch!(attrs, :attempt_id))
    authorize_open!(actor, attempt)

    request_id = Map.get(attrs, :request_id)

    case Repo.get_by(Question, attempt_id: attempt.id, request_id: request_id) do
      %Question{} = existing ->
        existing

      nil ->
        question =
          Txn.insert!(
            Question.changeset(%Question{}, %{
              mission_id: attempt.mission_id,
              attempt_id: attempt.id,
              request_id: request_id,
              blocking_scope: Map.get(attrs, :blocking_scope),
              requested_authority: Map.get(attrs, :requested_authority),
              status: "open",
              prompt: Map.get(attrs, :prompt),
              recommendation: Map.get(attrs, :recommendation),
              subject_type: Map.get(attrs, :subject_type),
              subject_id: Map.get(attrs, :subject_id)
            })
          )

        unless question.subject_type == "gate" do
          Txn.insert!(
            MissionBlocker.changeset(%MissionBlocker{}, %{
              mission_id: attempt.mission_id,
              kind: "question",
              reason: question.prompt,
              status: "open",
              subject_type: "question",
              subject_id: question.id
            })
          )
        end

        Txn.append_event!("question.opened", "question", question.id)
        question
    end
  end

  def route(question_id, actor) do
    DatabaseWriter.transaction(fn -> route_txn(question_id, actor) end)
  end

  def route_txn(question_id, actor) do
    Txn.require_principal(actor, ["daemon", "boss"])
    question = fetch!(question_id)
    require_status!(question, "open", "routed")

    {route, reason} = route_for(question.requested_authority)

    question =
      Txn.update!(
        Question.changeset(question, %{status: "routed", route: route, routing_reason: reason})
      )

    Txn.insert!(
      OutboxItem.changeset(%OutboxItem{}, %{
        kind: "notification",
        status: "queued",
        idempotency_key: "question.routed:" <> question.id,
        natural_key: "question:" <> question.id,
        next_attempt_at: Txn.now(),
        payload: %{
          "question_id" => question.id,
          "route" => route,
          "routing_reason" => reason
        }
      })
    )

    Txn.append_event!("question.routed", "question", question.id, %{route: route})
    question
  end

  def answer(question_id, actor, attrs) do
    DatabaseWriter.transaction(fn -> answer_txn(question_id, actor, attrs) end)
  end

  def answer_txn(question_id, actor, attrs) do
    question = fetch!(question_id)
    authorize_answer!(actor, question)

    unless question.status in @openish do
      Txn.illegal(question.status, "answered", :terminal)
    end

    question =
      Txn.update!(
        Question.changeset(question, %{
          status: "answered",
          answer: Map.fetch!(attrs, :answer),
          answered_by_principal: actor.principal,
          answer_channel: Map.get(attrs, :answer_channel, actor.channel),
          answered_at: Txn.now()
        })
      )

    close_blocker!(question, "answered")
    Txn.append_event!("question.answered", "question", question.id)
    question
  end

  def withdraw(question_id, actor, reason) do
    DatabaseWriter.transaction(fn -> withdraw_txn(question_id, actor, reason) end)
  end

  def withdraw_txn(question_id, actor, reason) do
    Txn.require_principal(actor, ["boss", "daemon"])
    question = fetch!(question_id)

    unless question.status in @openish do
      Txn.illegal(question.status, "withdrawn", :terminal)
    end

    if reason in [nil, ""], do: Txn.illegal(question.status, "withdrawn", :reason_required)

    question = Txn.update!(Question.changeset(question, %{status: "withdrawn"}))
    close_blocker!(question, "withdrawn")
    Txn.append_event!("question.withdrawn", "question", question.id, %{reason: reason})
    question
  end

  def expire(question_id, actor) do
    DatabaseWriter.transaction(fn -> expire_txn(question_id, actor) end)
  end

  def expire_txn(question_id, actor) do
    Txn.require_principal(actor, ["daemon"])
    question = fetch!(question_id)

    unless question.status in @openish do
      Txn.illegal(question.status, "expired", :terminal)
    end

    question = Txn.update!(Question.changeset(question, %{status: "expired"}))

    Txn.insert!(
      Incident.changeset(%Incident{}, %{
        mission_id: question.mission_id,
        subject_type: "question",
        subject_id: question.id,
        severity: "warning",
        reason: "question expired without an answer"
      })
    )

    Txn.append_event!("question.expired", "question", question.id)
    question
  end

  def supersede(question_id, actor) do
    DatabaseWriter.transaction(fn -> supersede_txn(question_id, actor) end)
  end

  def supersede_txn(question_id, actor) do
    Txn.require_principal(actor, ["daemon", "boss"])
    question = fetch!(question_id)

    unless question.status in @openish do
      Txn.illegal(question.status, "superseded", :terminal)
    end

    unless question.blocking_scope == "attempt" do
      Txn.illegal(question.status, "superseded", :mission_scoped)
    end

    question = Txn.update!(Question.changeset(question, %{status: "superseded"}))
    close_blocker!(question, "superseded")
    Txn.append_event!("question.superseded", "question", question.id)
    question
  end

  defp fetch!(id) do
    case Repo.get(Question, id) do
      nil -> Txn.illegal(nil, nil, :not_found)
      question -> question
    end
  end

  defp fetch_attempt!(id) do
    case Repo.get(Attempt, id) do
      nil -> Txn.illegal(nil, nil, :not_found)
      attempt -> attempt
    end
  end

  defp require_status!(question, from, to) do
    if question.status == from, do: :ok, else: Txn.illegal(question.status, to, :wrong_status)
  end

  defp authorize_open!(actor, attempt) do
    case actor.principal do
      "daemon" ->
        :ok

      "attempt" ->
        cond do
          actor.attempt_id != attempt.id ->
            Txn.fenced(attempt.id)

          actor.fencing_token != attempt.fencing_token ->
            Txn.fenced(attempt.id)

          attempt.status in @attempt_terminal ->
            Txn.fenced(attempt.id)

          true ->
            case Capabilities.revalidate_actor(actor, attempt) do
              :ok -> :ok
              {:error, reason} -> Txn.unauthorized(reason)
            end
        end

      _ ->
        Txn.unauthorized(:principal)
    end
  end

  defp authorize_answer!(actor, question) do
    cond do
      question.requested_authority == "boss" and actor.principal != "boss" ->
        Txn.unauthorized(:boss_required)

      actor.principal == "attempt" ->
        Txn.unauthorized(:principal)

      actor.principal == "model_advisory" and question.requested_authority == "boss" ->
        Txn.unauthorized(:boss_required)

      actor.principal in ["boss", "daemon"] ->
        :ok

      actor.principal == question.requested_authority ->
        :ok

      actor.principal == "model_advisory" ->
        Txn.unauthorized(:not_delegated)

      true ->
        Txn.unauthorized(:principal)
    end
  end

  defp route_for("boss"), do: {"boss_inbox", "boss_authority"}
  defp route_for(other), do: {other, "delegated"}

  defp close_blocker!(question, reason) do
    from(b in MissionBlocker,
      where:
        b.mission_id == ^question.mission_id and b.kind == "question" and b.status == "open" and
          b.subject_id == ^question.id
    )
    |> Repo.all()
    |> Enum.each(fn blocker ->
      Txn.update!(
        MissionBlocker.changeset(blocker, %{
          status: "closed",
          closed_reason: reason,
          closed_at: Txn.now()
        })
      )
    end)
  end
end
