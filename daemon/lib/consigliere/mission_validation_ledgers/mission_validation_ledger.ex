defmodule Consigliere.MissionValidationLedgers.MissionValidationLedger do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "mission_validation_ledgers" do
    field(:mission_id, :binary_id)
    field(:gate_type, :string)
    field(:total_failed_runs, :integer, default: 0)
    field(:total_repair_rounds, :integer, default: 0)
    field(:total_infrastructure_retries, :integer, default: 0)
    field(:identical_finding_counts_json, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  @required [:mission_id, :gate_type]
  @optional [
    :total_failed_runs,
    :total_repair_rounds,
    :total_infrastructure_retries,
    :identical_finding_counts_json
  ]

  def changeset(ledger, attrs) do
    ledger
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> Consigliere.SqliteConstraints.foreign_key_constraint(:mission_id)
    |> unique_constraint([:mission_id, :gate_type])
  end
end
