defmodule Consigliere.ProjectVerifications.VerificationRun do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @outcomes ~w(running passed failed infrastructure_error canceled)

  def outcomes, do: @outcomes

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "project_verification_runs" do
    field(:attempt_id, :binary_id)
    field(:mission_id, :binary_id)
    field(:result_id, :binary_id)
    field(:gate_type, :string)
    field(:ordinal, :integer)
    field(:command_identity, :string)
    field(:argv, :map, default: %{})
    field(:input_sha, :string)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:exit_status, :integer)
    field(:timed_out, :boolean, default: false)
    field(:output_bytes, :integer, default: 0)
    field(:output_digest, :string)
    field(:outcome, :string, default: "running")
    field(:error_code, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @required [
    :attempt_id,
    :mission_id,
    :result_id,
    :gate_type,
    :ordinal,
    :command_identity,
    :argv,
    :input_sha,
    :started_at,
    :outcome
  ]
  @optional [
    :finished_at,
    :exit_status,
    :timed_out,
    :output_bytes,
    :output_digest,
    :error_code
  ]

  def changeset(run, attrs) do
    run
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:outcome, @outcomes)
    |> validate_number(:ordinal, greater_than: 0)
    |> validate_number(:output_bytes, greater_than_or_equal_to: 0)
    |> validate_length(:error_code, max: 128)
    |> unique_constraint([:attempt_id, :gate_type, :ordinal])
    |> Consigliere.SqliteConstraints.foreign_key_constraint(:attempt_id)
    |> Consigliere.SqliteConstraints.foreign_key_constraint(:mission_id)
    |> Consigliere.SqliteConstraints.foreign_key_constraint(:result_id)
  end
end
