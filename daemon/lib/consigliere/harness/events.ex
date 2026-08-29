defmodule Consigliere.Harness.Events do
  @moduledoc """
  Ingests adapter events through DatabaseWriter. Deduplicates by event_id,
  rejects a stale fencing token or a non-increasing native_sequence, and
  persists native_session_id from session.started. A superseded Attempt
  cannot complete (Phase 3 late-completion test).
  """

  alias Consigliere.Attempts.Attempt
  alias Consigliere.Capabilities
  alias Consigliere.DatabaseWriter
  alias Consigliere.HarnessEvents.HarnessEvent
  alias Consigliere.Repo
  alias Consigliere.Txn

  @live ~w(starting running checkpoint_requested)
  @types ~w(session.started turn.started progress.reported artifact.created
            question.requested checkpoint.created usage.updated turn.completed
            session.completed session.failed)

  def ingest(event, actor) do
    DatabaseWriter.transaction(fn -> ingest_txn(event, actor) end)
  end

  def ingest_txn(event, actor) when is_map(event) do
    attempt_id = Map.get(event, "attempt_id")
    event_id = Map.get(event, "event_id")
    type = Map.get(event, "type")
    seq = Map.get(event, "native_sequence")
    payload = Map.get(event, "payload", %{})

    unless is_binary(attempt_id) and is_binary(event_id) and is_binary(type) and is_integer(seq) do
      Repo.rollback(:malformed)
    end

    unless type in @types do
      Repo.rollback(:unknown_event_type)
    end

    if payload_too_large?(payload) do
      Repo.rollback(:payload_too_large)
    end

    attempt = fetch_attempt!(attempt_id)
    require_fence!(actor, attempt)

    case Repo.get_by(HarnessEvent, event_id: event_id) do
      %HarnessEvent{} ->
        :duplicate

      nil ->
        reject_stale_sequence!(attempt, seq)

        Txn.insert!(
          HarnessEvent.changeset(%HarnessEvent{}, %{
            event_id: event_id,
            attempt_id: attempt.id,
            type: type,
            native_sequence: seq,
            payload: payload
          })
        )

        attrs = %{last_native_sequence: seq, last_event_at: Txn.now()}
        attrs = maybe_session(type, payload, attrs)
        attempt = Txn.update!(Attempt.changeset(attempt, attrs))
        Txn.append_event!(type, "attempt", attempt.id, payload)
        apply_type(type, attempt, payload, actor)
        :accepted
    end
  end

  defp maybe_session("session.started", payload, attrs) do
    attrs =
      case payload do
        %{"native_session_id" => id} when is_binary(id) and id != "" ->
          Map.put(attrs, :native_session_id, id)

        _ ->
          attrs
      end

    case payload do
      %{"input_context_hash" => hash} when is_binary(hash) ->
        Map.put(attrs, :input_context_hash, hash)

      _ ->
        attrs
    end
  end

  defp maybe_session(_type, _payload, attrs), do: attrs

  defp apply_type("session.completed", attempt, _payload, _actor) do
    Txn.update!(Attempt.changeset(attempt, %{exit_classification: "completed"}))
  end

  defp apply_type("session.failed", attempt, payload, _actor) do
    klass = Map.get(payload, "class") || Map.get(payload, "reason") || "failed"
    Txn.update!(Attempt.changeset(attempt, %{exit_classification: to_string(klass)}))
  end

  defp apply_type("checkpoint.created", attempt, payload, actor) do
    sha = Map.get(payload, "sha") || Map.get(payload, "commit_sha")

    if is_binary(sha) and sha != "" do
      Consigliere.Attempts.Transitions.request_checkpoint_txn(attempt.id, actor, %{
        reported_checkpoint_sha: sha
      })
    else
      :ok
    end
  end

  defp apply_type("question.requested", attempt, payload, actor) do
    Consigliere.Questions.Transitions.open_txn(
      %{
        attempt_id: attempt.id,
        request_id: Map.get(payload, "request_id") || "q-#{attempt.id}",
        blocking_scope: Map.get(payload, "blocking_scope", "attempt"),
        requested_authority: Map.get(payload, "requested_authority", "boss"),
        prompt: Map.get(payload, "question") || Map.get(payload, "prompt") || "",
        recommendation: Map.get(payload, "recommendation")
      },
      actor
    )
  end

  defp apply_type(_type, _attempt, _payload, _actor), do: :ok

  defp fetch_attempt!(id) do
    case Repo.get(Attempt, id) do
      nil -> Txn.illegal(nil, nil, :not_found)
      attempt -> attempt
    end
  end

  defp require_fence!(actor, attempt) do
    cond do
      actor.principal != "attempt" ->
        Txn.unauthorized(:principal)

      actor.attempt_id != attempt.id ->
        Txn.fenced(attempt.id)

      actor.fencing_token != attempt.fencing_token ->
        Txn.fenced(attempt.id)

      attempt.status not in @live ->
        Txn.fenced(attempt.id)

      true ->
        case Capabilities.revalidate_actor(actor, attempt) do
          :ok -> :ok
          {:error, reason} -> Txn.unauthorized(reason)
        end
    end
  end

  defp payload_too_large?(payload) do
    byte_size(inspect(payload, limit: :infinity)) > 16_384
  end

  defp reject_stale_sequence!(attempt, seq) do
    last = attempt.last_native_sequence

    if is_integer(last) and seq <= last do
      Repo.rollback(:stale_sequence)
    else
      :ok
    end
  end
end
