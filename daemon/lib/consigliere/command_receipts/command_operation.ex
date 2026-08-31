defmodule Consigliere.CommandReceipts.CommandOperation do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending committed recovery_required)

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "command_operations" do
    field(:receipt_id, :binary_id)
    field(:op, :string)
    field(:principal, :string)
    field(:payload, :map, default: %{})
    field(:status, :string, default: "pending")
    field(:evidence, :map, default: %{})
    field(:response, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(operation, attrs) do
    operation
    |> cast(attrs, [:receipt_id, :op, :principal, :payload, :status, :evidence, :response])
    |> validate_required([:receipt_id, :op, :principal, :payload])
    |> validate_inclusion(:status, @statuses)
  end
end
