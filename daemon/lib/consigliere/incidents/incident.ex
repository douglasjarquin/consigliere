defmodule Consigliere.Incidents.Incident do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "incidents" do
    field(:mission_id, :binary_id)
    field(:subject_type, :string)
    field(:subject_id, :binary_id)
    field(:severity, :string)
    field(:reason, :string)
    field(:resolved_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:severity, :reason]
  @optional [:mission_id, :subject_type, :subject_id, :resolved_at]

  def changeset(incident, attrs) do
    incident
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> Consigliere.SqliteConstraints.foreign_key_constraint(:mission_id)
  end
end
