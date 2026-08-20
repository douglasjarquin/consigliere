defmodule Consigliere.Harness.FakeTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Fixtures
  alias Consigliere.Harness
  alias Consigliere.Harness.Fake
  alias Consigliere.Missions
  alias Consigliere.Questions.Question
  alias Consigliere.Repo

  setup do
    Fixtures.reset_phase1_tables!()
    Fake.reset!()
    :ok
  end

  defp running_spec! do
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

    spec = %{
      attempt_id: attempt.id,
      fencing_token: attempt.fencing_token,
      context_pack: "do the thing"
    }

    {attempt, spec}
  end

  test "cold start emits session.started before turn.started and persists native_session_id" do
    {attempt, spec} = running_spec!()
    assert {:ok, ref, :fresh} = Harness.open_session(Fake, spec)
    assert is_binary(ref.native_session_id) and ref.native_session_id != ""

    updated = Repo.get!(Attempt, attempt.id)
    assert updated.native_session_id == ref.native_session_id
    assert updated.last_native_sequence == 2
    assert is_binary(updated.input_context_hash)

    types = Fixtures.event_types(attempt.id)
    started = Enum.find_index(types, &(&1 == "session.started"))
    turn = Enum.find_index(types, &(&1 == "turn.started"))
    assert started < turn
  end

  test "resume of an unknown session falls back to exactly one fresh start" do
    {_attempt, spec} = running_spec!()
    assert Fake.start_count() == 0

    assert {:ok, _ref, :fresh} =
             Harness.open_session(Fake, Map.put(spec, :native_session_id, "no-such-session"))

    assert Fake.start_count() == 1
  end

  test "resume of a known session does not start again" do
    {_attempt, spec} = running_spec!()
    {:ok, ref, :fresh} = Harness.open_session(Fake, spec)
    assert Fake.start_count() == 1

    assert {:ok, resumed, :resumed} =
             Harness.open_session(Fake, Map.put(spec, :native_session_id, ref.native_session_id))

    assert resumed.native_session_id == ref.native_session_id
    assert Fake.start_count() == 1
  end

  test "question.requested opens a durable Question" do
    {_attempt, spec} = running_spec!()
    {:ok, _ref, :fresh} = Harness.open_session(Fake, spec)
    assert {:ok, :accepted} = Fake.request_question(spec, "ship it?")
    assert Repo.aggregate(Question, :count) == 1
    assert Repo.one!(Question).prompt == "ship it?"
  end

  test "interrupt does not cancel the session" do
    {_attempt, spec} = running_spec!()
    {:ok, ref, :fresh} = Harness.open_session(Fake, spec)
    assert :ok = Fake.interrupt(ref)
    assert Fake.interrupted?(ref)
    assert :ok = Fake.send(ref, "continue")
    assert Fake.snapshot(ref).native_session_id == ref.native_session_id
  end
end
