defmodule Consigliere.Authorizations.Authorization do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @scopes ~w(work integration policy_override)

  def scopes, do: @scopes

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "authorizations" do
    field(:mission_id, :binary_id)
    field(:scope, :string)
    field(:granted_by_principal, :string)
    field(:target_pull_request, :string)
    field(:target_sha, :string)
    field(:granted_at, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:mission_id, :scope, :granted_by_principal, :granted_at]
  @optional [:target_pull_request, :target_sha, :consumed_at, :expires_at, :revoked_at]

  def changeset(authorization, attrs) do
    authorization
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:scope, @scopes)
    |> Consigliere.SqliteConstraints.foreign_key_constraint(:mission_id)
  end
end
