defmodule Consigliere.Repo.Migrations.DecisionPolicyAndFingerprint do
  use Ecto.Migration

  def change do
    alter table(:decisions) do
      add :policy_hash, :string
      add :finding_fingerprint, :string
    end
  end
end
