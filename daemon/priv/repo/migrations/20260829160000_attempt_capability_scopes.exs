defmodule Consigliere.Repo.Migrations.AttemptCapabilityScopes do
  use Ecto.Migration

  def up do
    alter table(:attempt_capabilities) do
      add(:generation, :integer, null: false, default: 1)
      add(:workspace_id, references(:workspaces, type: :binary_id))
      add(:workspace_generation, :string)
      add(:issued_at, :utc_datetime_usec)
    end

    execute("""
    WITH ranked AS (
      SELECT id,
             ROW_NUMBER() OVER (PARTITION BY attempt_id ORDER BY inserted_at, id) AS generation
      FROM attempt_capabilities
    )
    UPDATE attempt_capabilities
    SET generation = (
      SELECT ranked.generation
      FROM ranked
      WHERE ranked.id = attempt_capabilities.id
    )
    """)

    execute("""
    UPDATE attempt_capabilities
    SET workspace_id = (
          SELECT attempts.workspace_id
          FROM attempts
          WHERE attempts.id = attempt_capabilities.attempt_id
        ),
        workspace_generation = (
          SELECT workspaces.lease_id
          FROM attempts
          JOIN workspaces ON workspaces.id = attempts.workspace_id
          WHERE attempts.id = attempt_capabilities.attempt_id
        ),
        issued_at = inserted_at
    WHERE issued_at IS NULL
    """)

    create(unique_index(:attempt_capabilities, [:attempt_id, :generation]))
    create(index(:attempt_capabilities, [:attempt_id, :revoked_at]))
  end

  def down do
    drop_if_exists(index(:attempt_capabilities, [:attempt_id, :revoked_at]))
    drop_if_exists(unique_index(:attempt_capabilities, [:attempt_id, :generation]))

    alter table(:attempt_capabilities) do
      remove(:issued_at)
      remove(:workspace_generation)
      remove(:workspace_id)
      remove(:generation)
    end
  end
end
