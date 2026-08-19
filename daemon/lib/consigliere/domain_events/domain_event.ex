defmodule Consigliere.DomainEvents.DomainEvent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "domain_events" do
    field(:type, :string)
    field(:subject_type, :string)
    field(:subject_id, :binary_id)
    field(:payload, :map, default: %{})
    field(:occurred_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required [:type, :subject_type, :subject_id, :occurred_at]
  @optional [:payload]

  def changeset(event, attrs) do
    event
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
  end
end
