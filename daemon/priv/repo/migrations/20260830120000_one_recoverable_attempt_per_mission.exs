defmodule Consigliere.Repo.Migrations.OneRecoverableAttemptPerMission do
  use Ecto.Migration

  def change do
    create(
      unique_index(
        :attempts,
        [:mission_id],
        name: :attempts_one_recoverable_per_mission,
        where: "status IN ('planned', 'starting')"
      )
    )
  end
end
