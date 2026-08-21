defmodule Consigliere.Txn do
  @moduledoc false

  alias Consigliere.Repo
  alias Consigliere.DomainEvents.DomainEvent

  def now do
    DateTime.utc_now() |> DateTime.truncate(:microsecond)
  end

  def insert!(changeset) do
    case Repo.insert(changeset) do
      {:ok, struct} -> struct
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  def update!(changeset) do
    case Repo.update(changeset) do
      {:ok, struct} -> struct
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  def append_event!(type, subject_type, subject_id, payload \\ %{}) do
    insert!(
      DomainEvent.changeset(%DomainEvent{}, %{
        type: type,
        subject_type: subject_type,
        subject_id: subject_id,
        payload: payload,
        occurred_at: now()
      })
    )
  end

  def illegal(from, to, reason) do
    Repo.rollback({:illegal_transition, %{from: from, to: to, reason: reason}})
  end

  def unauthorized(reason) do
    Repo.rollback({:unauthorized, reason})
  end

  def fenced(attempt_id) do
    Repo.rollback({:fenced, attempt_id})
  end

  def sha_mismatch(expected, got) do
    Repo.rollback({:sha_mismatch, %{expected: expected, got: got}})
  end

  def run_id_mismatch(expected, got) do
    Repo.rollback({:run_id_mismatch, %{expected: expected, got: got}})
  end

  def require_principal(actor, allowed) when is_list(allowed) do
    if actor.principal in allowed do
      :ok
    else
      unauthorized(:principal)
    end
  end

  def mint_fencing_token do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
