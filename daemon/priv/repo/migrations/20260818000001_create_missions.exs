defmodule Consigliere.Repo.Migrations.CreateMissions do
  use Ecto.Migration

  def change do
    create table(:missions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :objective, :text, null: false
      add :scope, :text, null: false
      add :acceptance_criteria, :text, null: false
      add :phase, :string, null: false, default: "draft"
      add :replaces_mission_id, references(:missions, type: :binary_id), null: true
      add :validation_policy, :map, null: false, default: %{}
      add :current_checkpoint_sha, :string
      add :current_delivery_sha, :string
      add :terminal_reason, :text
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end
  end
end
