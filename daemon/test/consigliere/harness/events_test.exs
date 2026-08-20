defmodule Consigliere.Harness.EventsTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Fixtures
  alias Consigliere.Harness.Events
  alias Consigliere.Missions
  alias Consigliere.Repo

  setup do
    Fixtures.reset_phase1_tables!()
    :ok
  end

  defp running_attempt! do
    {:ok, mission} =
      Missions.create(Fixtures.mission_attrs(), Actor.boss())

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Missions.grant_work_authorization(mission.id, Actor.boss())

    {:ok, %{attempt: attempt}} =
      Missions.start(mission.id, Actor.system(), %{
        workspace_path: "/tmp/cs-#{System.unique_integer([:positive])}"
      })

    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())

    {:ok, attempt} =
      Attempts.mark_running(attempt.id, Actor.system(), %{fencing_token: attempt.fencing_token})

    attempt
  end

  defp envelope(attempt, overrides) do
    Map.merge(
      %{
        "event_id" => "evt-#{System.unique_integer([:positive])}",
        "type" => "progress.reported",
        "native_sequence" => 1,
        "attempt_id" => attempt.id,
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "payload" => %{}
      },
      overrides
    )
  end

  test "first event is persisted and advances last_native_sequence" do
    attempt = running_attempt!()
    actor = Actor.attempt(attempt.id, attempt.fencing_token)
    event = envelope(attempt, %{"native_sequence" => 3, "event_id" => "e-first"})

    assert {:ok, :accepted} = Events.ingest(event, actor)
    updated = Repo.get!(Attempt, attempt.id)
    assert updated.last_native_sequence == 3
    assert updated.last_event_at != nil
  end

  test "duplicate event_id is a no-op" do
    attempt = running_attempt!()
    actor = Actor.attempt(attempt.id, attempt.fencing_token)
    event = envelope(attempt, %{"event_id" => "e-dup", "native_sequence" => 1})

    assert {:ok, :accepted} = Events.ingest(event, actor)
    assert {:ok, :duplicate} = Events.ingest(event, actor)
    assert Repo.get!(Attempt, attempt.id).last_native_sequence == 1
  end

  test "stale fencing_token is rejected" do
    attempt = running_attempt!()
    actor = Actor.attempt(attempt.id, "not-the-token")
    event = envelope(attempt, %{})

    assert {:error, {:fenced, id}} = Events.ingest(event, actor)
    assert id == attempt.id
    assert Repo.get!(Attempt, attempt.id).last_native_sequence == nil
  end

  test "a lower native_sequence from a new event_id is rejected" do
    attempt = running_attempt!()
    actor = Actor.attempt(attempt.id, attempt.fencing_token)

    assert {:ok, :accepted} =
             Events.ingest(
               envelope(attempt, %{"event_id" => "e-hi", "native_sequence" => 5}),
               actor
             )

    assert {:error, :stale_sequence} =
             Events.ingest(
               envelope(attempt, %{"event_id" => "e-lo", "native_sequence" => 4}),
               actor
             )

    assert Repo.get!(Attempt, attempt.id).last_native_sequence == 5
  end

  test "session.started persists native_session_id on the Attempt" do
    attempt = running_attempt!()
    actor = Actor.attempt(attempt.id, attempt.fencing_token)

    event =
      envelope(attempt, %{
        "type" => "session.started",
        "payload" => %{"native_session_id" => "sess-abc"}
      })

    assert {:ok, :accepted} = Events.ingest(event, actor)
    assert Repo.get!(Attempt, attempt.id).native_session_id == "sess-abc"
  end

  test "a truncated event missing event_id is malformed, not a silent success" do
    attempt = running_attempt!()
    actor = Actor.attempt(attempt.id, attempt.fencing_token)

    assert {:error, :malformed} =
             Events.ingest(%{"type" => "progress.reported", "attempt_id" => attempt.id}, actor)

    assert Repo.get!(Attempt, attempt.id).last_native_sequence == nil
  end

  test "session.completed records an exit classification on a live Attempt" do
    attempt = running_attempt!()
    actor = Actor.attempt(attempt.id, attempt.fencing_token)

    assert {:ok, :accepted} =
             Events.ingest(
               envelope(attempt, %{"type" => "session.completed", "native_sequence" => 2}),
               actor
             )

    assert Repo.get!(Attempt, attempt.id).exit_classification == "completed"
    assert Repo.get!(Attempt, attempt.id).status == "running"
  end

  test "unknown event types are rejected" do
    attempt = running_attempt!()
    actor = Actor.attempt(attempt.id, attempt.fencing_token)

    assert {:error, :unknown_event_type} =
             Events.ingest(envelope(attempt, %{"type" => "evil.dump"}), actor)
  end

  test "late session.completed from a superseded Attempt is fenced" do
    attempt = running_attempt!()
    old_token = attempt.fencing_token

    {:ok, %{attempt: old}} =
      Attempts.supersede(attempt.id, Actor.system(), %{role: "soldier", harness: "claude"})

    actor = Actor.attempt(old.id, old_token)

    event =
      envelope(old, %{
        "type" => "session.completed",
        "native_sequence" => 99
      })

    assert {:error, {:fenced, id}} = Events.ingest(event, actor)
    assert id == old.id
    assert Repo.get!(Attempt, old.id).status == "superseded"
  end
end
