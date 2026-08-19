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
    field(:leased_until, :utc_datetime_usec)
    field(:attempts, :integer, default: 0)
    field(:last_error, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:kind, :status]
  @optional [:payload, :leased_until, :attempts, :last_error]

  def changeset(item, attrs) do
    item
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
  end
end
