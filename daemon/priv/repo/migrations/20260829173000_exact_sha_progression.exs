defmodule Consigliere.Repo.Migrations.ExactSHAProgression do
  use Ecto.Migration

  def change do
    alter table(:attempts) do
      add(:imported_sha, :string)
      add(:result_ref, :string)
    end

    create table(:attempt_results, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:attempt_id, references(:attempts, type: :binary_id), null: false)
      add(:mission_id, references(:missions, type: :binary_id), null: false)
      add(:project_id, references(:projects, type: :binary_id), null: false)
      add(:workspace_id, references(:workspaces, type: :binary_id), null: false)
      add(:reported_sha, :string, null: false)
      add(:imported_sha, :string)
      add(:result_ref, :string)
      add(:result_kind, :string, null: false)
      add(:workspace_generation, :string, null: false)
      add(:base_sha, :string, null: false)
      add(:parent_checkpoint_sha, :string)
      add(:fencing_generation, :string, null: false)
      add(:accepted_terminal_sequence, :integer, null: false)
      add(:status, :string, null: false, default: "reported")
      add(:failure_code, :string)
      add(:failure_detail, :string)
      add(:verified_at, :utc_datetime_usec)
      add(:imported_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:attempt_results, [:attempt_id]))
    create(index(:attempt_results, [:mission_id]))
    create(index(:attempt_results, [:status]))

    create table(:project_verification_runs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:attempt_id, references(:attempts, type: :binary_id), null: false)
      add(:mission_id, references(:missions, type: :binary_id), null: false)
      add(:result_id, references(:attempt_results, type: :binary_id), null: false)
      add(:gate_type, :string, null: false)
      add(:ordinal, :integer, null: false)
      add(:command_identity, :string, null: false)
      add(:argv, :map, null: false)
      add(:input_sha, :string, null: false)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:finished_at, :utc_datetime_usec)
      add(:exit_status, :integer)
      add(:timed_out, :boolean, null: false, default: false)
      add(:output_bytes, :integer, null: false, default: 0)
      add(:output_digest, :string)
      add(:outcome, :string, null: false, default: "running")
      add(:error_code, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:project_verification_runs, [:attempt_id, :gate_type, :ordinal]))
    create(index(:project_verification_runs, [:mission_id, :input_sha]))
  end
end
