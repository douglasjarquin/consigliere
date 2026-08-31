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

  test "return does not remove a newer marker after acknowledging its snapshot" do
    assert Away.mark() == :ok

    File.write!(Away.path(), "newer-marker")

    digest = Away.return()

    assert is_map(digest)
    assert Away.marked?()
    assert is_nil(Repo.get_by!(BossCursor, name: "boss").away_since)
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

  test "return acknowledges only the bounded event page" do
    assert Away.mark() == :ok

    Enum.each(1..33, fn _index ->
      Repo.insert!(
        DomainEvent.changeset(%DomainEvent{}, %{
          type: "mission.created",
          subject_type: "mission",
          subject_id: Ecto.UUID.generate(),
          occurred_at: DateTime.utc_now()
        })
      )
    end)

    first = Away.return()
    first_ids = Enum.map(first["events"], & &1["id"])

    assert length(first_ids) == 32
    assert Repo.get_by!(BossCursor, name: "boss").last_event_id == List.last(first_ids)

    second = Away.return()
    assert length(second["events"]) == 1
    assert hd(second["events"])["id"] > List.last(first_ids)
  end

  test "overlapping returns never move the cursor backwards" do
    assert Away.mark() == :ok

    events =
      Enum.map(1..64, fn _index ->
        Repo.insert!(
          DomainEvent.changeset(%DomainEvent{}, %{
            type: "mission.created",
            subject_type: "mission",
            subject_id: Ecto.UUID.generate(),
            occurred_at: DateTime.utc_now()
          })
        )
      end)

    run_concurrent_returns = fn ->
      parent = self()

      tasks =
        Enum.map(1..20, fn _index ->
          Task.async(fn ->
            send(parent, {:away_return_ready, self()})

            receive do
              :start -> Away.return()
            end
          end)
        end)

      Enum.each(tasks, fn _task ->
        assert_receive {:away_return_ready, _pid}, 5_000
      end)

      Enum.each(tasks, &send(&1.pid, :start))
      Enum.map(tasks, &Task.await(&1, 5_000))
    end

    first_results = run_concurrent_returns.()

    assert Enum.all?(first_results, fn
             result when is_map(result) -> true
             {:error, :stale_away_return} -> true
           end)

    assert {:error, :stale_away_return} in first_results

    first_cursor = Repo.get_by!(BossCursor, name: "boss").last_event_id
    assert first_cursor == Enum.at(events, 31).id

    second_results = run_concurrent_returns.()

    assert Enum.all?(second_results, &is_map/1)
    assert Repo.get_by!(BossCursor, name: "boss").last_event_id == List.last(events).id
  end

  test "mark serializes marker and cursor updates behind the home lock" do
    parent = self()
    home = Path.expand(Path.dirname(Away.path()))

    lock_holder =
      Task.async(fn ->
        :global.trans({{Away, home}, self()}, fn ->
          send(parent, :away_lock_held)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :away_lock_held, 5_000

    tasks =
      Enum.map(1..2, fn _index ->
        Task.async(fn ->
          send(parent, {:away_mark_ready, self()})

          receive do
            :start ->
              assert Away.mark() == :ok
              send(parent, :away_mark_finished)
              :ok
          end
        end)
      end)

    Enum.each(tasks, fn _task ->
      assert_receive {:away_mark_ready, _pid}, 5_000
    end)

    Enum.each(tasks, &send(&1.pid, :start))
    refute_receive :away_mark_finished, 100
    send(lock_holder.pid, :release)
    assert Task.await(lock_holder, 5_000) == :ok

    assert Enum.all?(Enum.map(tasks, &Task.await(&1, 5_000)), &(&1 == :ok))
    assert_receive :away_mark_finished, 5_000
    assert_receive :away_mark_finished, 5_000

    cursor = Repo.get_by!(BossCursor, name: "boss")
    assert File.read!(Away.path()) == DateTime.to_iso8601(cursor.away_since)

    assert is_map(Away.return())
    refute Away.marked?()
  end
end
