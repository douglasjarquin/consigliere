defmodule Consigliere.Missions.Mission do
  @moduledoc """
  Minimal Mission projection for Phase 0 Spike A.

  This schema exists only to give the serialized-writer spike a real
  table to write concurrently against. Full Mission fields per
  docs/state-machines/mission.md land in Phase 1.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "missions" do
    field(:title, :string)
    field(:phase, :string, default: "draft")

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(mission, attrs) do
    mission
    |> cast(attrs, [:title, :phase])
    |> validate_required([:title, :phase])
  end
end
