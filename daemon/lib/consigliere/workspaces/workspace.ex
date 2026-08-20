defmodule Consigliere.Workspaces.Workspace do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active daemon_exclusive quarantined released)

  def statuses, do: @statuses

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "workspaces" do
    field(:mission_id, :binary_id)
    field(:path, :string)
    field(:lease_id, :string)
    field(:fencing_token, :string)
    field(:status, :string, default: "active")
    field(:quarantine_reason, :string)
    field(:project_id, :binary_id)
    field(:base_sha, :string)
    field(:parent_checkpoint_sha, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:mission_id, :path, :lease_id, :fencing_token, :status]
  @optional [:quarantine_reason, :project_id, :base_sha, :parent_checkpoint_sha]

  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> Consigliere.SqliteConstraints.foreign_key_constraint(:mission_id)
  end
end
