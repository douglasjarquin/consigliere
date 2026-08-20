defmodule Consigliere.Repo.Migrations.AddHarnessAdapterColumns do
  use Ecto.Migration

  def change do
    alter table(:attempts) do
      add :native_session_id, :string
      add :input_context_hash, :string
      add :last_native_sequence, :integer
    end

    create table(:harness_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :event_id, :string, null: false
      add :attempt_id, references(:attempts, type: :binary_id), null: false
      add :type, :string, null: false
      add :native_sequence, :integer, null: false
      add :payload, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:harness_events, [:event_id])
    create index(:harness_events, [:attempt_id])
  end
end
