defmodule Consigliere.Gates.Gate do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending running passed needs_decision failed_retryable
               failed_terminal canceled invalidated)

  def statuses, do: @statuses

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "gates" do
    field(:mission_id, :binary_id)
    field(:gate_type, :string)
    field(:input_sha, :string)
    field(:base_sha, :string)
    field(:policy_hash, :string)
    field(:status, :string, default: "pending")
    field(:managed_run_id, :string)
    field(:output_sha, :string)
    field(:finding_digest, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:mission_id, :gate_type, :input_sha, :base_sha, :policy_hash, :status]
  @optional [:managed_run_id, :output_sha, :finding_digest]

  def changeset(gate, attrs) do
    gate
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> Consigliere.SqliteConstraints.foreign_key_constraint(:mission_id)
    |> unique_constraint([:mission_id, :gate_type, :input_sha, :base_sha, :policy_hash])
  end
end
