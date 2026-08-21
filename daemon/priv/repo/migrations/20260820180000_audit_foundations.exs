defmodule Consigliere.Repo.Migrations.AuditFoundations do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :repository_path, :string
      add :repository_url, :string, null: false
      add :default_branch, :string, null: false, default: "main"
      add :trusted_mirror_path, :string, null: false
      add :dispatch_policy, :map, default: %{}
      add :validation_policy, :map, default: %{}
      add :integration_policy, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:projects, [:repository_url])

    alter table(:missions) do
      add :project_id, references(:projects, type: :binary_id), null: true
    end

    create index(:missions, [:project_id])

    create table(:command_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :idempotency_key, :string, null: false
      add :op, :string, null: false
      add :principal, :string, null: false
      add :payload_hash, :string, null: false
      add :response, :map, null: false, default: %{}
      add :status, :string, null: false, default: "committed"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:command_receipts, [:principal, :idempotency_key])

    create table(:boss_cursors, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :last_event_id, :integer, null: false, default: 0
      add :away_since, :utc_datetime_usec
      add :acknowledged_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:boss_cursors, [:name])

    create table(:attempt_capabilities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :secret_hash, :string, null: false
      add :attempt_id, references(:attempts, type: :binary_id), null: false
      add :mission_id, references(:missions, type: :binary_id), null: false
      add :ops, :map, null: false, default: %{}
      add :fencing_token, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:attempt_capabilities, [:secret_hash])
    create index(:attempt_capabilities, [:attempt_id])
  end
end
