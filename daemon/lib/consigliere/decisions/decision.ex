defmodule Consigliere.Decisions.Decision do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @scopes ~w(mission_finding_waiver project_policy_override sha_bound)

  def scopes, do: @scopes

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "decisions" do
    field(:mission_id, :binary_id)
    field(:scope, :string)
    field(:input_sha, :string)
    field(:base_sha, :string)
    field(:granted_by_principal, :string)
    field(:reason, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:scope, :granted_by_principal]
  @optional [:mission_id, :input_sha, :base_sha, :reason]

  def changeset(decision, attrs) do
    decision
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:scope, @scopes)
    |> Consigliere.SqliteConstraints.foreign_key_constraint(:mission_id)
  end
end
