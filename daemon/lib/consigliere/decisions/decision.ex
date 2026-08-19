defmodule Consigliere.Decisions.Decision do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @scopes ~w(mission_finding_waiver project_policy_override sha_bound)

  def scopes, do: @scopes

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "decisions" do
    field(:mission_id, :binary_id)
    field(:question_id, :binary_id)
    field(:scope, :string)
    field(:input_sha, :string)
    field(:base_sha, :string)
    field(:granted_by_principal, :string)
    field(:reason, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:maximum_uses, :integer)
    field(:revoked_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:scope, :granted_by_principal]
  @optional [
    :mission_id,
    :question_id,
    :input_sha,
    :base_sha,
    :reason,
    :expires_at,
    :maximum_uses,
    :revoked_at
  ]

  def changeset(decision, attrs) do
    decision
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:scope, @scopes)
    |> Consigliere.SqliteConstraints.foreign_key_constraint(:mission_id)
    |> Consigliere.SqliteConstraints.foreign_key_constraint(:question_id)
  end
end
