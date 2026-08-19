defmodule Consigliere.Repo.Migrations.CreatePhase1Schema do
  use Ecto.Migration

  def change do
    create table(:authorizations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :mission_id, references(:missions, type: :binary_id), null: false
      add :scope, :string, null: false
      add :granted_by_principal, :string, null: false
      add :target_pull_request, :string
      add :target_sha, :string
      add :granted_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:authorizations, [:mission_id])

    create table(:workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :mission_id, references(:missions, type: :binary_id), null: false
      add :path, :string, null: false
      add :lease_id, :string, null: false
      add :fencing_token, :string, null: false
      add :status, :string, null: false, default: "active"
      add :quarantine_reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:workspaces, [:mission_id])

    create table(:attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :mission_id, references(:missions, type: :binary_id), null: false
      add :workspace_id, references(:workspaces, type: :binary_id), null: true
      add :retry_of_attempt_id, references(:attempts, type: :binary_id), null: true
      add :role, :string, null: false
      add :harness, :string, null: false
      add :status, :string, null: false, default: "planned"
      add :fencing_token, :string, null: false
      add :runner_pid, :integer
      add :harness_pid, :integer
      add :pgid, :integer
      add :exit_classification, :string
      add :last_event_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:attempts, [:mission_id])
    create index(:attempts, [:status])

    create table(:questions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :mission_id, references(:missions, type: :binary_id), null: false
      add :attempt_id, references(:attempts, type: :binary_id), null: false
      add :request_id, :string, null: false
      add :blocking_scope, :string, null: false
      add :requested_authority, :string, null: false
      add :status, :string, null: false, default: "open"
      add :prompt, :text, null: false
      add :recommendation, :text
      add :subject_type, :string
      add :subject_id, :binary_id
      add :routing_reason, :string
      add :route, :string
      add :answer, :text
      add :answered_by_principal, :string
      add :answer_channel, :string
      add :answered_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:questions, [:mission_id])
    create unique_index(:questions, [:attempt_id, :request_id])

    create table(:gates, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :mission_id, references(:missions, type: :binary_id), null: false
      add :gate_type, :string, null: false
      add :input_sha, :string, null: false
      add :base_sha, :string, null: false
      add :policy_hash, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :managed_run_id, :string
      add :output_sha, :string
      add :finding_digest, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:gates, [:mission_id])

    create unique_index(
             :gates,
             [:mission_id, :gate_type, :input_sha, :base_sha, :policy_hash],
             where: "status != 'invalidated'"
           )

    create table(:mission_blockers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :mission_id, references(:missions, type: :binary_id), null: false
      add :kind, :string, null: false
      add :reason, :text
      add :status, :string, null: false, default: "open"
      add :closed_reason, :string
      add :closed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:mission_blockers, [:mission_id])
    create index(:mission_blockers, [:status])

    create table(:mission_validation_ledgers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :mission_id, references(:missions, type: :binary_id), null: false
      add :gate_type, :string, null: false
      add :total_failed_runs, :integer, null: false, default: 0
      add :total_repair_rounds, :integer, null: false, default: 0
      add :total_infrastructure_retries, :integer, null: false, default: 0
      add :identical_finding_counts_json, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mission_validation_ledgers, [:mission_id, :gate_type])

    create table(:incidents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :mission_id, references(:missions, type: :binary_id), null: true
      add :subject_type, :string
      add :subject_id, :binary_id
      add :severity, :string, null: false
      add :reason, :text, null: false
      add :resolved_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:incidents, [:mission_id])

    create table(:decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :mission_id, references(:missions, type: :binary_id), null: true
      add :scope, :string, null: false
      add :input_sha, :string
      add :base_sha, :string
      add :granted_by_principal, :string, null: false
      add :reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:decisions, [:mission_id])

    create table(:domain_events) do
      add :type, :string, null: false
      add :subject_type, :string, null: false
      add :subject_id, :binary_id, null: false
      add :payload, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:domain_events, [:subject_type, :subject_id])

    create table(:outbox_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :status, :string, null: false, default: "queued"
      add :leased_until, :utc_datetime_usec
      add :attempts, :integer, null: false, default: 0
      add :last_error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:outbox_items, [:status])
  end
end
