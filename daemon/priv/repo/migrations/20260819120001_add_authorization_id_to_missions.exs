defmodule Consigliere.Repo.Migrations.AddAuthorizationIdToMissions do
  use Ecto.Migration

  def change do
    alter table(:missions) do
      add :authorization_id, references(:authorizations, type: :binary_id), null: true
    end
  end
end
