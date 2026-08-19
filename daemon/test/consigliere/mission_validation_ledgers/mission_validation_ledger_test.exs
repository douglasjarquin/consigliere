defmodule Consigliere.MissionValidationLedgers.MissionValidationLedgerTest do
  use ExUnit.Case, async: true

  alias Consigliere.Repo
  alias Consigliere.Fixtures
  alias Consigliere.MissionValidationLedgers.MissionValidationLedger

  test "a valid changeset inserts with default counters and round-trips" do
    mission = Fixtures.mission!()
    attrs = %{mission_id: mission.id, gate_type: "review"}

    assert {:ok, ledger} =
             Repo.insert(MissionValidationLedger.changeset(%MissionValidationLedger{}, attrs))

    reloaded = Repo.get(MissionValidationLedger, ledger.id)
    assert reloaded.total_failed_runs == 0
    assert reloaded.total_repair_rounds == 0
  end

  test "the ledger is unique per (mission_id, gate_type)" do
    mission = Fixtures.mission!()
    attrs = %{mission_id: mission.id, gate_type: "review"}

    assert {:ok, _} =
             Repo.insert(MissionValidationLedger.changeset(%MissionValidationLedger{}, attrs))

    assert {:error, changeset} =
             Repo.insert(MissionValidationLedger.changeset(%MissionValidationLedger{}, attrs))

    refute changeset.valid?
  end
end
