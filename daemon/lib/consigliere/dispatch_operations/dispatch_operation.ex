defmodule Consigliere.DispatchOperations.DispatchOperation do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending spawn_requested child_started failed completed)
  @slot_states ~w(granted held released)
  @child_states ~w(not_started started failed)

  def statuses, do: @statuses

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "dispatch_operations" do
    field(:mission_id, :binary_id)
    field(:attempt_id, :binary_id)
    field(:workspace_id, :binary_id)
    field(:fencing_token, :string)
    field(:status, :string, default: "pending")
    field(:slot_state, :string)
    field(:child_start_state, :string, default: "not_started")
    field(:spawn_attempts, :integer, default: 0)
    field(:last_error, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:mission_id, :attempt_id, :fencing_token, :status]
  @optional [
    :workspace_id,
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
