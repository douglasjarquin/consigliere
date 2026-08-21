defmodule Consigliere.Harness.ContextPackTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Fixtures
  alias Consigliere.Harness.ContextPack
  alias Consigliere.Missions

  setup do
    Fixtures.reset_phase1_tables!()
    :ok
  end

  test "compose includes the authorized Mission contract and hashes the canonical encoding" do
    {:ok, mission} =
      Missions.create(
        Fixtures.mission_attrs(%{
          objective: "add ping",
          scope: "lib/ping.ex",
          acceptance_criteria: "ping returns pong"
        }),
        Actor.boss()
      )

    assert {:ok, result} =
             ContextPack.compose(mission, %{
               workspace_path: "/tmp/ws",
               base_sha: "abc123",
               role: "soldier"
             })

    assert result.pack["objective"] == "add ping"
    assert result.pack["scope"] == "lib/ping.ex"
    assert result.pack["acceptance_criteria"] == "ping returns pong"
    assert result.pack["mission_id"] == mission.id
    assert result.pack["project_id"] == mission.project_id
    assert result.pack["workspace_path"] == "/tmp/ws"
    assert result.pack["base_sha"] == "abc123"
    assert result.pack["authority"]["may_grant_work"] == false
    refute result.encoded =~ "boss.secret"
    refute result.encoded =~ "complete the authorized mission"
    assert result.hash == ContextPack.hash(result.encoded)

    assert {:ok, again} =
             ContextPack.compose(mission, %{
               workspace_path: "/tmp/ws",
               base_sha: "abc123",
               role: "soldier"
             })

    assert result.hash == again.hash
  end

  test "compose rejects an oversized pack" do
    {:ok, mission} =
      Missions.create(
        Fixtures.mission_attrs(%{objective: String.duplicate("x", 70_000)}),
        Actor.boss()
      )

    assert {:error, :too_large} = ContextPack.compose(mission)
  end
end
