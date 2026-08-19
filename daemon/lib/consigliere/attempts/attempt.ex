defmodule Consigliere.Attempts.Attempt do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(planned starting running checkpoint_requested checkpointed
               completed failed lost canceled superseded)

  def statuses, do: @statuses

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "attempts" do
    field(:mission_id, :binary_id)
    field(:workspace_id, :binary_id)
    field(:retry_of_attempt_id, :binary_id)
    field(:role, :string)
    field(:harness, :string)
    field(:status, :string, default: "planned")
    field(:fencing_token, :string)
    field(:runner_pid, :integer)
    field(:harness_pid, :integer)
    field(:pgid, :integer)
    field(:exit_classification, :string)
    field(:reported_checkpoint_sha, :string)
    field(:last_event_at, :utc_datetime_usec)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:mission_id, :role, :harness, :status, :fencing_token]
  @optional [
    :workspace_id,
    :retry_of_attempt_id,
    :runner_pid,
    :harness_pid,
    :pgid,
    :exit_classification,
    :reported_checkpoint_sha,
    :last_event_at,
    :started_at,
    :finished_at
  ]

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> Consigliere.SqliteConstraints.foreign_key_constraint(:mission_id)
    |> Consigliere.SqliteConstraints.foreign_key_constraint(:workspace_id)
    |> Consigliere.SqliteConstraints.foreign_key_constraint(:retry_of_attempt_id)
  end
end
