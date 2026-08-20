defmodule Consigliere.CommandReceipts.CommandReceipt do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "command_receipts" do
    field(:idempotency_key, :string)
    field(:op, :string)
    field(:principal, :string)
    field(:payload_hash, :string)
    field(:response, :map, default: %{})
    field(:status, :string, default: "committed")

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:idempotency_key, :op, :principal, :payload_hash, :response, :status])
    |> validate_required([:idempotency_key, :op, :principal, :payload_hash])
    |> unique_constraint([:principal, :idempotency_key])
  end
end
