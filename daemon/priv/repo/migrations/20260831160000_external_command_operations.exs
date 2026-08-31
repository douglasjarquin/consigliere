defmodule Consigliere.Repo.Migrations.ExternalCommandOperations do
  use Ecto.Migration

  def change do
    create table(:command_operations, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:receipt_id, references(:command_receipts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:op, :string, null: false)
      add(:principal, :string, null: false)
      add(:payload, :map, null: false, default: %{})
      add(:status, :string, null: false, default: "pending")
      add(:evidence, :map, null: false, default: %{})
      add(:response, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:command_operations, [:receipt_id]))
    create(index(:command_operations, [:status]))

    alter table(:command_receipts) do
      add(:operation_id, :binary_id, null: true)
    end

    create(index(:command_receipts, [:operation_id]))
  end
end
