defmodule Consigliere.Questions.Question do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(open routed answered withdrawn expired superseded)
  @blocking_scopes ~w(attempt mission)

  def statuses, do: @statuses
  def blocking_scopes, do: @blocking_scopes

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "questions" do
    field(:mission_id, :binary_id)
    field(:attempt_id, :binary_id)
    field(:request_id, :string)
    field(:blocking_scope, :string)
    field(:requested_authority, :string)
    field(:status, :string, default: "open")
    field(:prompt, :string)
    field(:recommendation, :string)
    field(:subject_type, :string)
    field(:subject_id, :binary_id)
    field(:routing_reason, :string)
    field(:route, :string)
    field(:answer, :string)
    field(:answered_by_principal, :string)
    field(:answer_channel, :string)
    field(:answered_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @required [
    :mission_id,
    :attempt_id,
    :request_id,
    :blocking_scope,
    :requested_authority,
    :status,
    :prompt
  ]
  @optional [
    :recommendation,
    :subject_type,
    :subject_id,
    :routing_reason,
    :route,
    :answer,
    :answered_by_principal,
    :answer_channel,
    :answered_at
  ]

  def changeset(question, attrs) do
    question
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:blocking_scope, @blocking_scopes)
    |> Consigliere.SqliteConstraints.foreign_key_constraint(:mission_id)
    |> Consigliere.SqliteConstraints.foreign_key_constraint(:attempt_id)
    |> unique_constraint([:attempt_id, :request_id], error_key: :request_id)
  end
end
