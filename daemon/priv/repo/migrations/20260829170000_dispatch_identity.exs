defmodule Consigliere.Repo.Migrations.DispatchIdentity do
  use Ecto.Migration

  def change do
    alter table(:dispatch_operations) do
      add(:correlation_id, :string)
      add(:idempotency_key, :string)
      add(:authorization_id, :binary_id)
      add(:project_id, :binary_id)
      add(:workspace_generation, :string)
      add(:base_sha, :string)
      add(:parent_checkpoint_sha, :string)
    end

    create(unique_index(:dispatch_operations, [:mission_id, :idempotency_key]))
  end
end
