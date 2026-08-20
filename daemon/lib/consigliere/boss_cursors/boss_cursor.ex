defmodule Consigliere.BossCursors.BossCursor do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "boss_cursors" do
    field(:name, :string)
    field(:last_event_id, :integer, default: 0)
    field(:away_since, :utc_datetime_usec)
    field(:acknowledged_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:name, :last_event_id, :away_since, :acknowledged_at])
    |> validate_required([:name, :last_event_id])
    |> unique_constraint(:name)
  end
end
