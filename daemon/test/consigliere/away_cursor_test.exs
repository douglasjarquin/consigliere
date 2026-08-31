defmodule Consigliere.AwayCursorTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Away
  alias Consigliere.BossCursors.BossCursor
  alias Consigliere.DomainEvents.DomainEvent
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

  test "return bounds event digests before acknowledging oversized payloads" do
    assert Away.mark() == :ok
    marked_at = Repo.get_by!(BossCursor, name: "boss").last_event_id

    Repo.insert!(
      DomainEvent.changeset(%DomainEvent{}, %{
        type: "mission.created",
        subject_type: "mission",
        subject_id: Ecto.UUID.generate(),
        occurred_at: DateTime.utc_now(),
        payload: %{"prompt" => String.duplicate("secret-shaped", 10_000)}
      })
    )

    digest = Away.return()

    assert is_map(digest)
    assert Enum.all?(digest["events"], &(!Map.has_key?(&1, "payload")))
    assert Repo.get_by!(BossCursor, name: "boss").last_event_id > marked_at
  end
end
