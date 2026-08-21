defmodule Consigliere.Missions.MissionTest do
  use ExUnit.Case, async: true

  alias Consigliere.Repo
  alias Consigliere.Fixtures
  alias Consigliere.Missions.Mission

  test "a valid changeset inserts with default phase draft and round-trips" do
    attrs = %{objective: "ship it", scope: "just this repo", acceptance_criteria: "tests pass"}

    assert {:ok, mission} = Repo.insert(Mission.changeset(%Mission{}, attrs))
    assert Repo.get(Mission, mission.id).phase == "draft"
  end

  test "an unknown phase is rejected" do
    attrs = %{
      objective: "o",
      scope: "s",
      acceptance_criteria: "a",
      phase: "not_a_real_phase"
    }

    refute Mission.changeset(%Mission{}, attrs).valid?
  end

  test "missing objective is rejected" do
    attrs = %{scope: "s", acceptance_criteria: "a"}
    refute Mission.changeset(%Mission{}, attrs).valid?
  end

  test "replaces_mission_id points at another Mission (supersession forward pointer)" do
    original = Fixtures.mission!()

    attrs = %{
      objective: "o2",
      scope: "s2",
      acceptance_criteria: "a2",
      replaces_mission_id: original.id
    }

    assert {:ok, replacement} = Repo.insert(Mission.changeset(%Mission{}, attrs))
    assert Repo.get(Mission, replacement.id).replaces_mission_id == original.id
  end
end
