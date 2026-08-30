defmodule Consigliere.AttemptResults.AttemptResult do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(reported death_verified commit_verified imported failed)
  @kinds ~w(completed checkpoint)

  def statuses, do: @statuses
  def kinds, do: @kinds

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "attempt_results" do
    field(:attempt_id, :binary_id)
    field(:mission_id, :binary_id)
    field(:project_id, :binary_id)
    field(:workspace_id, :binary_id)
    field(:reported_sha, :string)
    field(:imported_sha, :string)
    field(:result_ref, :string)
    field(:result_kind, :string)
    field(:workspace_generation, :string)
    field(:base_sha, :string)
    field(:parent_checkpoint_sha, :string)
    field(:fencing_generation, :string)
    field(:accepted_terminal_sequence, :integer)
    field(:status, :string, default: "reported")
    field(:failure_code, :string)
    field(:failure_detail, :string)
    field(:verified_at, :utc_datetime_usec)
    field(:imported_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @required [
    :attempt_id,
    :mission_id,
    :project_id,
    :workspace_id,
    :reported_sha,
    :result_kind,
    :workspace_generation,
    :base_sha,
    :fencing_generation,
    :accepted_terminal_sequence,
    :status
  ]
  @optional [
    :imported_sha,
    :result_ref,
    :parent_checkpoint_sha,
    :failure_code,
    :failure_detail,
    :verified_at,
    :imported_at
  ]

  def changeset(result, attrs) do
    result
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:result_kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:accepted_terminal_sequence, greater_than: 0)
    |> validate_length(:failure_code, max: 128)
    |> validate_length(:failure_detail, max: 512)
    |> Consigliere.SqliteConstraints.foreign_key_constraint(:attempt_id)
    |> Consigliere.SqliteConstraints.foreign_key_constraint(:mission_id)
    |> Consigliere.SqliteConstraints.foreign_key_constraint(:project_id)
    |> Consigliere.SqliteConstraints.foreign_key_constraint(:workspace_id)
  end
end
