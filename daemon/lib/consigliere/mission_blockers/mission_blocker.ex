defmodule Consigliere.MissionBlockers.MissionBlocker do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(open closed)

  def statuses, do: @statuses

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "mission_blockers" do
    field(:mission_id, :binary_id)
    field(:kind, :string)
    field(:reason, :string)
    field(:status, :string, default: "open")
    field(:closed_reason, :string)
    field(:closed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:mission_id, :kind, :status]
  @optional [:reason, :closed_reason, :closed_at]

  def changeset(blocker, attrs) do
    blocker
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> Consigliere.SqliteConstraints.foreign_key_constraint(:mission_id)
  end
end
