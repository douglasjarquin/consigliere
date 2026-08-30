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
               attempt_id: "attempt-1",
               workspace_id: "workspace-1",
               workspace_path: "/tmp/ws",
               workspace_generation: "lease-1",
               fencing_generation: "fence-1",
               invocation_id: "invocation-1",
               base_sha: "abc123",
               role: "soldier",
               model: "gpt-5",
               effort: "high",
               sandbox: "workspace-write",
               approval: "never",
               cli_version: "codex 1.2.3"
             })

    assert result.pack["objective"] == "add ping"
    assert result.pack["scope"] == "lib/ping.ex"
    assert result.pack["acceptance_criteria"] == "ping returns pong"
    assert result.pack["mission_id"] == mission.id
    assert result.pack["project_id"] == mission.project_id
    assert result.pack["workspace_path"] == "/tmp/ws"
    assert result.pack["attempt_id"] == "attempt-1"
    assert result.pack["workspace_id"] == "workspace-1"
    assert result.pack["workspace_generation"] == "lease-1"
    assert result.pack["fencing_generation"] == "fence-1"
    assert result.pack["invocation_id"] == "invocation-1"
    assert result.pack["base_sha"] == "abc123"
    assert result.pack["execution"]["model"] == "gpt-5"
    assert result.pack["execution"]["effort"] == "high"
    assert result.pack["execution"]["sandbox"] == "workspace-write"
    assert result.pack["execution"]["approval"] == "never"
    assert result.pack["execution"]["cli_version"] == "codex 1.2.3"
    assert result.pack["checkpoint"]["sha"] == mission.current_checkpoint_sha
    assert is_integer(result.bytes)
    assert is_integer(result.input_tokens)
    assert result.bytes == byte_size(result.encoded)
    assert result.input_tokens <= 8_192
    assert result.pack["instructions"]
    assert result.pack["authority"]["may_grant_work"] == false
    assert result.pack["protocol"]["reporter"] == "$CS_ATTEMPT_BIN"

    assert result.pack["capability"]["operations"] ==
             Consigliere.Capabilities.worker_operations()

    refute result.encoded =~ "boss.secret"
    refute result.encoded =~ "complete the authorized mission"

    {:ok, protected} =
      ContextPack.compose(mission, %{
        capability: "reusable-secret",
        authority: %{"may_grant_work" => true},
        protocol: "caller-controlled"
      })

    refute protected.encoded =~ "reusable-secret"
    assert protected.pack["authority"]["may_grant_work"] == false
    assert result.hash == ContextPack.hash(result.encoded)

    assert {:ok, again} =
             ContextPack.compose(mission, %{
               attempt_id: "attempt-1",
               workspace_id: "workspace-1",
               workspace_path: "/tmp/ws",
               workspace_generation: "lease-1",
               fencing_generation: "fence-1",
               invocation_id: "invocation-1",
               base_sha: "abc123",
               role: "soldier",
               model: "gpt-5",
               effort: "high",
               sandbox: "workspace-write",
               approval: "never",
               cli_version: "codex 1.2.3"
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

  test "compose rejects a pack that exceeds the input-token bound before dispatch" do
    {:ok, mission} =
      Missions.create(
        Fixtures.mission_attrs(%{objective: String.duplicate("x", 40_000)}),
        Actor.boss()
      )

    assert {:error, :too_large} =
             ContextPack.compose(mission, %{workspace_path: "/tmp/ws"})
  end

  test "final completion does not require a checkpoint in the same Attempt" do
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())

    assert {:ok, result} = ContextPack.compose(mission)
    assert result.pack["completion"]["require_checkpoint"] == false
  end

  test "compose redacts credential-shaped mission content" do
    {:ok, mission} =
      Missions.create(
        Fixtures.mission_attrs(%{objective: "use ghp_example-secret only as a fixture"}),
        Actor.boss()
      )

    assert {:ok, result} = ContextPack.compose(mission)
    refute result.encoded =~ "ghp_example-secret"
    assert result.pack["objective"] =~ "[REDACTED]"
  end
end
