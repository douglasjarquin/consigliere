defmodule Consigliere.Repo.Migrations.CodexExecutionIdentity do
  use Ecto.Migration

  def change do
    alter table(:attempts) do
      add(:invocation_id, :string)
      add(:model, :string)
      add(:reasoning_effort, :string)
      add(:sandbox, :string)
      add(:approval, :string)
      add(:cli_version, :string)
      add(:context_bytes, :integer)
      add(:context_input_tokens, :integer)
    end

    create(unique_index(:attempts, [:invocation_id]))
  end
end
