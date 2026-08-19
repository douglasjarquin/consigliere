defmodule Consigliere.Repo.Migrations.AddWriterTransactionColumns do
  use Ecto.Migration

  def change do
    alter table(:mission_blockers) do
      add :subject_type, :string
      add :subject_id, :binary_id
    end

    alter table(:attempts) do
      add :reported_checkpoint_sha, :string
    end

    alter table(:decisions) do
      add :question_id, references(:questions, type: :binary_id), null: true
      add :expires_at, :utc_datetime_usec
      add :maximum_uses, :integer
      add :revoked_at, :utc_datetime_usec
    end

    alter table(:authorizations) do
      add :consumed_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
    end

    alter table(:outbox_items) do
      add :natural_key, :string
      add :idempotency_key, :string
      add :next_attempt_at, :utc_datetime_usec
    end

    create index(:decisions, [:question_id])
    create unique_index(:outbox_items, [:idempotency_key])
  end
end
