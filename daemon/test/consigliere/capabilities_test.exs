defmodule Consigliere.CapabilitiesTest do
  use ExUnit.Case, async: false

  alias Consigliere.API.Auth
  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Capabilities
  alias Consigliere.Capabilities.AttemptCapability
  alias Consigliere.Fixtures
  alias Consigliere.Missions
  alias Consigliere.Repo

  setup do
    Fixtures.reset_phase1_tables!()
    :ok
  end

  defp running_attempt! do
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

    attempt
  end

  test "capability socket derives the Attempt from the secret not JSON" do
    attempt = running_attempt!()
    {:ok, secret} = Capabilities.mint(attempt)

    actor =
      Auth.identify(
        %{"capability" => secret, "actor" => %{"principal" => "attempt"}},
        :capability
      )

    assert actor.principal == "attempt"
    assert actor.attempt_id == attempt.id
    assert actor.allowed_ops == Capabilities.worker_operations()

    assert {:error, "capability actor mismatch"} =
             Auth.identify(
               %{
                 "capability" => secret,
                 "actor" => %{"principal" => "attempt", "attempt_id" => Ecto.UUID.generate()}
               },
               :capability
             )
  end

  test "expired and revoked secrets fail closed" do
    attempt = running_attempt!()
    {:ok, secret} = Capabilities.mint(attempt, ttl_seconds: -1)
    assert {:error, "expired capability"} = Capabilities.authenticate(secret)

    {:ok, live} = Capabilities.mint(attempt)
    assert {:ok, _} = Capabilities.revoke_for_attempt(attempt.id)
    assert {:error, "revoked capability"} = Capabilities.authenticate(live)
  end

  test "capability socket rejects boss and daemon claims without a token" do
    assert {:error, _} = Auth.identify(%{"actor" => %{"principal" => "boss"}}, :capability)
    assert {:error, _} = Auth.identify(%{"actor" => %{"principal" => "daemon"}}, :capability)
  end

  test "mint stores the closed generation-bound worker scope" do
    attempt = running_attempt!()
    workspace = Repo.get!(Consigliere.Workspaces.Workspace, attempt.workspace_id)
    {:ok, secret} = Capabilities.mint(attempt)
    {:ok, capability} = Capabilities.authenticate(secret)

    assert capability.ops == %{"allow" => Capabilities.worker_operations()}
    assert capability.generation == 1
    assert capability.attempt_id == attempt.id
    assert capability.mission_id == attempt.mission_id
    assert capability.workspace_id == attempt.workspace_id
    assert capability.workspace_generation == workspace.lease_id
    assert capability.fencing_token == attempt.fencing_token
    assert DateTime.compare(capability.issued_at, DateTime.utc_now()) in [:lt, :eq]
  end

  test "mint rejects unknown or out-of-scope worker operations" do
    attempt = running_attempt!()

    assert {:error, {:invalid, "capability_operation_not_supported"}} =
             Capabilities.mint(attempt, ops: ["future.worker.op"])

    assert {:error, {:invalid, "capability_operation_not_supported"}} =
             Capabilities.mint(attempt, ops: ["mission.create"])
  end

  test "a new capability generation revokes the old generation" do
    attempt = running_attempt!()
    {:ok, first_secret} = Capabilities.mint(attempt, ttl_seconds: 1)
    {:ok, first} = Capabilities.authenticate(first_secret)
    {:ok, second_secret} = Capabilities.mint(attempt)

    assert {:error, "revoked capability"} = Capabilities.authenticate(first_secret)
    assert {:ok, second} = Capabilities.authenticate(second_secret)
    assert second.generation == first.generation + 1
    assert second.expires_at != first.expires_at
  end

  test "malformed durable scopes fail closed" do
    attempt = running_attempt!()
    {:ok, secret} = Capabilities.mint(attempt)
    {:ok, capability} = Capabilities.authenticate(secret)

    assert {:ok, _} =
             Repo.update(
               AttemptCapability.changeset(capability, %{ops: %{"allow" => ["not-a-worker-op"]}})
             )

    assert {:error, "malformed capability"} = Capabilities.authenticate(secret)
  end
end
