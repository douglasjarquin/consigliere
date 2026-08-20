defmodule Consigliere.CapabilitiesTest do
  use ExUnit.Case, async: false

  alias Consigliere.API.Auth
  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Capabilities
  alias Consigliere.Fixtures
  alias Consigliere.Missions

  setup do
    Fixtures.reset_phase1_tables!()
    :ok
  end

  defp running_attempt! do
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())
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
    assert actor.allowed_ops == ["ping", "mission.get", "question.open"]

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
end
