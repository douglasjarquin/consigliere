defmodule Consigliere.Capabilities.AttemptCapability do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "attempt_capabilities" do
    field(:secret_hash, :string)
    field(:attempt_id, :binary_id)
    field(:mission_id, :binary_id)
    field(:ops, :map, default: %{})
    field(:generation, :integer)
    field(:workspace_id, :binary_id)
    field(:workspace_generation, :string)
    field(:fencing_token, :string)
    field(:issued_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :secret_hash,
      :attempt_id,
      :mission_id,
      :ops,
      :generation,
      :workspace_id,
      :workspace_generation,
      :fencing_token,
      :issued_at,
      :expires_at,
      :revoked_at
    ])
    |> validate_required([
      :secret_hash,
      :attempt_id,
      :mission_id,
      :generation,
      :workspace_id,
      :workspace_generation,
      :fencing_token,
      :issued_at,
      :expires_at
    ])
    |> validate_number(:generation, greater_than: 0)
    |> unique_constraint(:secret_hash)
    |> unique_constraint([:attempt_id, :generation])
  end
end
