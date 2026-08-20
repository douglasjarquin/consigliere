defmodule Consigliere.Missions.Mission do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @phases ~w(draft awaiting_authorization authorized active ready_for_review
             awaiting_integration_authorization integrating completed failed
             canceled superseded)

  def phases, do: @phases

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "missions" do
    field(:objective, :string)
    field(:scope, :string)
    field(:acceptance_criteria, :string)
    field(:project_id, :binary_id)
    field(:phase, :string, default: "draft")
    field(:authorization_id, :binary_id)
    field(:replaces_mission_id, :binary_id)
    field(:validation_policy, :map, default: %{})
    field(:current_checkpoint_sha, :string)
    field(:current_delivery_sha, :string)
    field(:terminal_reason, :string)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:objective, :scope, :acceptance_criteria, :phase]
  @optional [
    :project_id,
    :authorization_id,
    :replaces_mission_id,
    :validation_policy,
    :current_checkpoint_sha,
    :current_delivery_sha,
    :terminal_reason,
    :started_at,
    :completed_at
  ]

  def changeset(mission, attrs) do
    mission
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:phase, @phases)
  end
end
