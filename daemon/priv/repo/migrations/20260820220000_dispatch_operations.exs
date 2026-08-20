defmodule Consigliere.Repo.Migrations.DispatchOperations do
  use Ecto.Migration

  def change do
    create table(:dispatch_operations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :mission_id, :binary_id, null: false
      add :attempt_id, :binary_id, null: false
      add :workspace_id, :binary_id
      add :fencing_token, :string, null: false
      add :status, :string, null: false
      add :slot_state, :string
      add :child_start_state, :string
      add :spawn_attempts, :integer, null: false, default: 0
      add :last_error, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:dispatch_operations, [:attempt_id])
    create index(:dispatch_operations, [:mission_id])
    create index(:dispatch_operations, [:status])
  end
end
