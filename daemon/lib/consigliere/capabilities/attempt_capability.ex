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
    field(:fencing_token, :string)
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
      :fencing_token,
      :expires_at,
      :revoked_at
    ])
    |> validate_required([:secret_hash, :attempt_id, :mission_id, :fencing_token, :expires_at])
    |> unique_constraint(:secret_hash)
  end
end
