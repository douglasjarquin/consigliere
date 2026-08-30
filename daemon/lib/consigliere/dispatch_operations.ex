defmodule Consigliere.DispatchOperations do
  @moduledoc false

  import Ecto.Query

  alias Consigliere.DatabaseWriter
  alias Consigliere.DispatchOperations.DispatchOperation
  alias Consigliere.Missions.Mission
  alias Consigliere.Repo
  alias Consigliere.Txn

  def get_by_attempt(attempt_id) do
    Repo.get_by(DispatchOperation, attempt_id: attempt_id)
  end

  def get_by_mission(mission_id) do
    Repo.one(
      from(o in DispatchOperation,
        where: o.mission_id == ^mission_id,
        order_by: [desc: o.inserted_at],
        limit: 1
      )
    )
  end

  def ensure(attempt, attrs \\ %{}) do
    DatabaseWriter.transaction(fn -> ensure_txn(attempt, attrs) end)
  end

  def ensure_txn(attempt, attrs \\ %{}) do
    case Repo.get_by(DispatchOperation, attempt_id: attempt.id) do
      %DispatchOperation{} = op ->
        op

      nil ->
        mission = Repo.get!(Mission, attempt.mission_id)

        workspace =
          attempt.workspace_id &&
            Repo.get(Consigliere.Workspaces.Workspace, attempt.workspace_id)

        Txn.insert!(
          DispatchOperation.changeset(%DispatchOperation{}, %{
            mission_id: attempt.mission_id,
            attempt_id: attempt.id,
            workspace_id: attempt.workspace_id,
            correlation_id: Map.get(attrs, :correlation_id) || Ecto.UUID.generate(),
            idempotency_key: Map.get(attrs, :idempotency_key) || "dispatch:#{attempt.id}",
            authorization_id: Map.get(attrs, :authorization_id) || mission.authorization_id,
            project_id: Map.get(attrs, :project_id) || mission.project_id,
            workspace_generation:
              Map.get(attrs, :workspace_generation) || (workspace && workspace.lease_id),
            base_sha:
              Map.get(attrs, :base_sha) || (workspace && workspace.base_sha) || mission.base_sha,
            parent_checkpoint_sha:
              Map.get(attrs, :parent_checkpoint_sha) ||
                (workspace && workspace.parent_checkpoint_sha) || mission.current_checkpoint_sha,
            fencing_token: attempt.fencing_token,
            status: Map.get(attrs, :status, "pending"),
            slot_state: Map.get(attrs, :slot_state, "pending"),
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

  def hold_slot(attempt_id) do
    DatabaseWriter.transaction(fn ->
      case Repo.get_by(DispatchOperation, attempt_id: attempt_id) do
        %DispatchOperation{slot_state: slot_state} = operation
        when slot_state in ["pending", "granted", "held"] ->
          Txn.update!(DispatchOperation.changeset(operation, %{slot_state: "unknown"}))

        _ ->
          :ok
      end
    end)
  end

  def release_held_slot(attempt_id) do
    DatabaseWriter.transaction(fn ->
      case Repo.get_by(DispatchOperation, attempt_id: attempt_id) do
        %DispatchOperation{slot_state: "unknown"} = operation ->
          Txn.update!(DispatchOperation.changeset(operation, %{slot_state: "released"}))

        _ ->
          :ok
      end
    end)
  end
end
