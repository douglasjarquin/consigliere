defmodule Consigliere.DispatchOperations do
  @moduledoc false

  alias Consigliere.DatabaseWriter
  alias Consigliere.DispatchOperations.DispatchOperation
  alias Consigliere.Repo
  alias Consigliere.Txn

  def get_by_attempt(attempt_id) do
    Repo.get_by(DispatchOperation, attempt_id: attempt_id)
  end

  def ensure(attempt, attrs \\ %{}) do
    DatabaseWriter.transaction(fn -> ensure_txn(attempt, attrs) end)
  end

  def ensure_txn(attempt, attrs \\ %{}) do
    case Repo.get_by(DispatchOperation, attempt_id: attempt.id) do
      %DispatchOperation{} = op ->
        op

      nil ->
        Txn.insert!(
          DispatchOperation.changeset(%DispatchOperation{}, %{
            mission_id: attempt.mission_id,
            attempt_id: attempt.id,
            workspace_id: attempt.workspace_id,
            fencing_token: attempt.fencing_token,
            status: Map.get(attrs, :status, "pending"),
            slot_state: Map.get(attrs, :slot_state, "granted"),
            child_start_state: Map.get(attrs, :child_start_state, "not_started")
          })
        )
    end
  end

  def update(op, attrs) do
    DatabaseWriter.transaction(fn ->
      Txn.update!(DispatchOperation.changeset(op, attrs))
    end)
  end
end
