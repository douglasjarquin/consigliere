defmodule Consigliere.Harness.CodexTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Fixtures
  alias Consigliere.Harness
  alias Consigliere.Harness.Codex
  alias Consigliere.Missions

  setup do
    Fixtures.reset_phase1_tables!()
    Codex.reset!()
    :ok
  end

  test "decode_line maps Codex exec JSON onto the adapter vocabulary" do
    assert {:event, "session.started", %{"native_session_id" => "t1"}} =
             Codex.decode_line(~s({"type":"thread.started","thread_id":"t1"}))

    assert {:event, "session.completed", _} =
             Codex.decode_line(~s({"type":"thread.completed"}))

    assert {:event, "session.failed", _} =
             Codex.decode_line(~s({"type":"error","message":"boom"}))
  end

  test "open_session cold start then unknown resume falls back once" do
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())
    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Fixtures.grant_work_quietly(mission.id, Actor.boss())

    {:ok, %{attempt: attempt}} =
      Missions.start(mission.id, Actor.system(), %{
        workspace_path: "/tmp/cs-#{System.unique_integer([:positive])}"
      })

    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())

    {:ok, attempt} =
      Attempts.mark_running(attempt.id, Actor.system(), %{fencing_token: attempt.fencing_token})

    spec = %{attempt_id: attempt.id, fencing_token: attempt.fencing_token, context_pack: "x"}
    assert {:ok, ref, :fresh} = Harness.open_session(Codex, spec)
    assert Codex.start_count() == 1

    assert {:ok, _, :fresh} =
             Harness.open_session(Codex, Map.put(spec, :native_session_id, "missing"))

    assert Codex.start_count() == 2
    assert is_binary(ref.native_session_id)
  end

  test "production config selects Codex not Fake" do
    config = File.read!(Path.expand("../../../config/config.exs", __DIR__))
    assert config =~ "harness_adapter: Consigliere.Harness.Codex"
    refute config =~ "harness_adapter: Consigliere.Harness.Fake"
  end
end
