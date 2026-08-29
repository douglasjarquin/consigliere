defmodule Consigliere.DispatchOperations.DispatchOperation do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending workspace_ready spawn_requested child_started unknown failed completed)
  @slot_states ~w(pending granted held released unknown)
  @child_states ~w(not_started started unknown failed)

  def statuses, do: @statuses

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "dispatch_operations" do
    field(:mission_id, :binary_id)
    field(:attempt_id, :binary_id)
    field(:workspace_id, :binary_id)
    field(:correlation_id, :string)
    field(:idempotency_key, :string)
    field(:authorization_id, :binary_id)
    field(:project_id, :binary_id)
    field(:workspace_generation, :string)
    field(:base_sha, :string)
    field(:parent_checkpoint_sha, :string)
    field(:fencing_token, :string)
    field(:status, :string, default: "pending")
    field(:slot_state, :string)
    field(:child_start_state, :string, default: "not_started")
    field(:spawn_attempts, :integer, default: 0)
    field(:last_error, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @required [
    :mission_id,
    :attempt_id,
    :correlation_id,
    :idempotency_key,
    :authorization_id,
    :project_id,
    :workspace_generation,
    :fencing_token,
    :status
  ]
  @optional [
    :workspace_id,
    :base_sha,
    :parent_checkpoint_sha,
    :slot_state,
    :child_start_state,
    :spawn_attempts,
    :last_error
  ]

  def changeset(op, attrs) do
    op
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:slot_state, @slot_states)
    |> validate_inclusion(:child_start_state, @child_states)
  end
end
