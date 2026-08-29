defmodule Consigliere.Repo.Migrations.BoundV0Records do
  use Ecto.Migration

  def change do
    alter table(:harness_events) do
      add(:protocol_version, :integer, null: false, default: 1)
      add(:correlation_id, :string)
      add(:logical_key, :string)
      add(:outcome, :string, null: false, default: "accepted")
    end

    create(index(:harness_events, [:attempt_id, :native_sequence]))
  end
end
