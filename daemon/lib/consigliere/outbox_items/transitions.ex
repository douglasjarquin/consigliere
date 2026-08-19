defmodule Consigliere.OutboxItems.Transitions do
  @moduledoc false

  import Ecto.Query

  alias Consigliere.DatabaseWriter
  alias Consigliere.Repo
  alias Consigliere.Txn
  alias Consigliere.OutboxItems.OutboxItem

  def claim_due(kinds, now, lease_until) do
    DatabaseWriter.transaction(fn -> claim_due_txn(kinds, now, lease_until) end)
  end

  def claim_due_txn(kinds, now, lease_until) do
    item =
      Repo.one(
        from i in OutboxItem,
          where:
            i.kind in ^kinds and
              ((i.status == "queued" and
                  (is_nil(i.next_attempt_at) or i.next_attempt_at <= ^now)) or
                 (i.status == "leased" and not is_nil(i.leased_until) and
                    i.leased_until <= ^now)),
          order_by: [asc: i.inserted_at],
          limit: 1
      )

    case item do
      nil ->
        nil

      item ->
        Txn.update!(
          OutboxItem.changeset(item, %{
            status: "leased",
            leased_until: lease_until,
            attempts: item.attempts + 1
          })
        )
    end
  end

  def complete(id) do
    DatabaseWriter.transaction(fn -> complete_txn(id) end)
  end

  def complete_txn(id) do
    item = fetch!(id)

    Txn.update!(
      OutboxItem.changeset(item, %{
        status: "completed",
        leased_until: nil,
        last_error: nil
      })
    )
  end

  def retry(id, error, next_attempt_at) do
    DatabaseWriter.transaction(fn -> retry_txn(id, error, next_attempt_at) end)
  end

  def retry_txn(id, error, next_attempt_at) do
    item = fetch!(id)

    Txn.update!(
      OutboxItem.changeset(item, %{
        status: "queued",
        leased_until: nil,
        last_error: error,
        next_attempt_at: next_attempt_at
      })
    )
  end

  def fail(id, error) do
    DatabaseWriter.transaction(fn -> fail_txn(id, error) end)
  end

  def fail_txn(id, error) do
    item = fetch!(id)

    Txn.update!(
      OutboxItem.changeset(item, %{
        status: "failed",
        leased_until: nil,
        last_error: error
      })
    )
  end

  defp fetch!(id) do
    case Repo.get(OutboxItem, id) do
      nil -> Txn.illegal(nil, nil, :not_found)
      item -> item
    end
  end
end
