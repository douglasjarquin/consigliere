defmodule Consigliere.Repo.Migrations.ProjectBaseAndWorkspaceIdentity do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :base_sha, :string
      add :base_ref, :string
    end

    alter table(:missions) do
      add :base_sha, :string
    end

    alter table(:workspaces) do
      add :project_id, :binary_id
      add :base_sha, :string
      add :parent_checkpoint_sha, :string
    end
  end
end
