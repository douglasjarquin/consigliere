defmodule Consigliere.OutboxItems.OutboxItem do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(queued leased completed failed)

  def statuses, do: @statuses

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "outbox_items" do
    field(:kind, :string)
    field(:payload, :map, default: %{})
    field(:status, :string, default: "queued")
    field(:natural_key, :string)
    field(:idempotency_key, :string)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:leased_until, :utc_datetime_usec)
    field(:attempts, :integer, default: 0)
    field(:last_error, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:kind, :status]
  @optional [
    :payload,
    :natural_key,
    :idempotency_key,
    :next_attempt_at,
    :leased_until,
    :attempts,
    :last_error
  ]

  def changeset(item, attrs) do
    item
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:idempotency_key)
  end
end
