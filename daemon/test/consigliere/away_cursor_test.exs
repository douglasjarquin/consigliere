defmodule Consigliere.AwayCursorTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Away
  alias Consigliere.BossCursors.BossCursor
  alias Consigliere.Fixtures
  alias Consigliere.Missions
  alias Consigliere.Repo

  setup do
    Fixtures.reset_phase1_tables!()
    File.rm(Away.path())
    :ok
  end

  test "return digest includes events since the AFK cursor and then acknowledges" do
    {:ok, _} = Missions.create(Fixtures.mission_attrs(%{objective: "before"}), Actor.boss())
    assert Away.mark() == :ok
    cursor = Repo.get_by!(BossCursor, name: "boss")
    marked_at = cursor.last_event_id

    {:ok, _} = Missions.create(Fixtures.mission_attrs(%{objective: "while-away"}), Actor.boss())
    digest = Away.return()
    refute Away.marked?()
    types = Enum.map(digest["events"], & &1["type"])
    assert "mission.created" in types
    assert is_integer(digest["cursor"])
    assert digest["cursor"] == marked_at

    acked = Repo.get_by!(BossCursor, name: "boss")
    assert acked.last_event_id > marked_at
    assert acked.acknowledged_at
    assert is_nil(acked.away_since)
  end

  test "inbox does not acknowledge the cursor" do
    assert Away.mark() == :ok
    {:ok, _} = Missions.create(Fixtures.mission_attrs(), Actor.boss())
    inbox = Away.digest(:inbox)
    assert inbox["events"] == []
    cursor = Repo.get_by!(BossCursor, name: "boss")
    assert is_nil(cursor.acknowledged_at)
  end
end
