defmodule Consigliere.HarnessEvents.HarnessEvent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "harness_events" do
    field(:event_id, :string)
    field(:attempt_id, :binary_id)
    field(:type, :string)
    field(:native_sequence, :integer)
    field(:protocol_version, :integer, default: 1)
    field(:correlation_id, :string)
    field(:logical_key, :string)
    field(:outcome, :string, default: "accepted")
    field(:payload, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  @required [:event_id, :attempt_id, :type, :native_sequence]
  @optional [:protocol_version, :correlation_id, :logical_key, :outcome, :payload]

  def changeset(event, attrs) do
    event
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(:event_id)
    |> Consigliere.SqliteConstraints.foreign_key_constraint(:attempt_id)
  end
end
