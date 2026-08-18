defmodule Consigliere.Repo.Migrations.CreateMissions do
  use Ecto.Migration

  def change do
    create table(:missions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :phase, :string, null: false, default: "draft"

      timestamps(type: :utc_datetime_usec)
    end
  end
end
