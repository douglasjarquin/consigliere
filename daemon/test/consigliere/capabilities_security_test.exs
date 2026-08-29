defmodule Consigliere.CapabilitiesSecurityTest do
  use ExUnit.Case, async: false

  alias Consigliere.API.Auth
  alias Consigliere.API.Protocol
  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Capabilities
  alias Consigliere.Fixtures
  alias Consigliere.Missions
  alias Consigliere.Repo

  setup do
    Fixtures.reset_phase1_tables!()
    :ok
  end

  test "the full V0 worker operation set works through an authenticated channel" do
    {mission, attempt} = running_attempt!()
    {secret, capability} = mint!(attempt)

    assert response("ping", %{}, secret, capability)["ok"]

    own = response("mission.get_own", %{"mission_id" => mission.id}, secret, capability)
    assert own["ok"]
    assert own["payload"]["id"] == mission.id

    progress = response("attempt.progress", %{"attempt_id" => attempt.id}, secret, capability)
    assert progress["ok"]
    assert progress["payload"]["id"] == attempt.id

    question =
      response(
        "question.open",
        %{
          "attempt_id" => attempt.id,
          "request_id" => "question-#{attempt.id}",
          "blocking_scope" => "attempt",
          "requested_authority" => "boss",
          "prompt" => "need a decision"
        },
        secret,
        capability
      )

    assert question["ok"]

    checkpoint =
      response(
        "attempt.checkpoint",
        %{
          "attempt_id" => attempt.id,
          "reported_checkpoint_sha" => "a" <> String.duplicate("0", 39)
        },
        secret,
        capability
      )

    assert checkpoint["ok"]
    assert checkpoint["payload"]["status"] == "checkpoint_requested"

    {_mission, completion_attempt} = running_attempt!()
    {completion_secret, completion_capability} = mint!(completion_attempt)

    completion =
      response(
        "attempt.complete",
        %{"attempt_id" => completion_attempt.id},
        completion_secret,
        completion_capability
      )

    assert completion["ok"]

    {_mission, failed_attempt} = running_attempt!()
    {failure_secret, failure_capability} = mint!(failed_attempt)

    failure =
      response(
        "attempt.fail",
        %{"attempt_id" => failed_attempt.id, "classification" => "harness_failed"},
        failure_secret,
        failure_capability
      )

    assert failure["ok"]
  end

  test "a one-operation capability cannot invoke another worker operation" do
    {mission, attempt} = running_attempt!()
    {secret, capability} = mint!(attempt, ops: ["ping"])

    assert response("ping", %{}, secret, capability)["ok"]
    before_events = Repo.aggregate(Consigliere.DomainEvents.DomainEvent, :count)

    denied =
      response(
        "mission.get_own",
        %{"mission_id" => mission.id},
        secret,
        capability
      )

    assert denied["ok"] == false
    assert denied["error"]["code"] == "unauthorized"
    assert Repo.aggregate(Consigliere.DomainEvents.DomainEvent, :count) == before_events
  end

  test "cross-attempt and cross-mission scope tampering is rejected before the writer" do
    {mission_a, attempt_a} = running_attempt!()
    {mission_b, attempt_b} = running_attempt!()
    {secret, capability} = mint!(attempt_a)
    before_events = Repo.aggregate(Consigliere.DomainEvents.DomainEvent, :count)

    cross_mission =
      response("mission.get_own", %{"mission_id" => mission_b.id}, secret, capability)

    cross_attempt =
      response("attempt.progress", %{"attempt_id" => attempt_b.id}, secret, capability)

    assert cross_mission["ok"] == false
    assert cross_attempt["ok"] == false
    assert cross_mission["error"]["code"] == "unauthorized"
    assert cross_attempt["error"]["code"] == "unauthorized"
    assert Repo.aggregate(Consigliere.DomainEvents.DomainEvent, :count) == before_events
    assert Repo.get!(Consigliere.Missions.Mission, mission_a.id).phase == "active"
  end

  test "altered capability, Attempt, workspace, and fence scope is rejected before mutation" do
    {_mission, attempt} = running_attempt!()
    {secret, capability} = mint!(attempt)
    before_receipts = Repo.aggregate(Consigliere.CommandReceipts.CommandReceipt, :count)
    before_events = Repo.aggregate(Consigliere.DomainEvents.DomainEvent, :count)

    tampered = [
      {"capability_id", Ecto.UUID.generate()},
      {"capability_generation", capability.generation + 1},
      {"attempt_id", Ecto.UUID.generate()},
      {"mission_id", Ecto.UUID.generate()},
      {"workspace_id", Ecto.UUID.generate()},
      {"workspace_generation", "stale-workspace-generation"},
      {"fencing_generation", "stale-fence"}
    ]

    Enum.each(tampered, fn {field, value} ->
      scope = scope(capability) |> Map.put(field, value)

      denied =
        response("attempt.progress", %{"attempt_id" => attempt.id}, secret, capability, scope)

      assert denied["ok"] == false
      assert denied["error"]["code"] == "unauthorized"
    end)

    assert Repo.aggregate(Consigliere.CommandReceipts.CommandReceipt, :count) == before_receipts
    assert Repo.aggregate(Consigliere.DomainEvents.DomainEvent, :count) == before_events
  end

  test "a capability actor is revalidated after authentication and before mutation" do
    {_mission, attempt} = running_attempt!()
    {secret, _capability} = mint!(attempt)

    actor = Auth.identify(%{"capability" => secret}, :capability)
    assert %Actor{principal: "attempt"} = actor
    assert {:ok, _} = Capabilities.revoke_for_attempt(attempt.id)

    assert {:error, {:unauthorized, :capability}} =
             Attempts.report_progress(attempt.id, actor)

    assert Repo.get!(Consigliere.Attempts.Attempt, attempt.id).last_event_at ==
             attempt.last_event_at
  end

  defp running_attempt! do
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())
    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Fixtures.grant_work_quietly(mission.id, Actor.boss())

    {:ok, %{mission: mission, attempt: attempt}} =
      Missions.start(mission.id, Actor.system(), %{
        workspace_path: "/tmp/cs-#{System.unique_integer([:positive])}"
      })

    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())

    {:ok, attempt} =
      Attempts.mark_running(attempt.id, Actor.system(), %{fencing_token: attempt.fencing_token})

    {mission, attempt}
  end

  defp mint!(attempt, opts \\ []) do
    {:ok, secret} = Capabilities.mint(attempt, opts)
    {:ok, capability} = Capabilities.authenticate(secret)
    {secret, capability}
  end

  defp response(op, payload, secret, capability, scope_override \\ nil) do
    request = %{
      "v" => 1,
      "id" => "cap-#{System.unique_integer([:positive])}",
      "op" => op,
      "capability" => secret,
      "scope" => scope_override || scope(capability),
      "payload" => payload
    }

    {:ok, response} = JSON.decode(Protocol.handle(JSON.encode!(request), :capability))
    response
  end

  defp scope(capability) do
    %{
      "capability_id" => capability.id,
      "capability_generation" => capability.generation,
      "attempt_id" => capability.attempt_id,
      "mission_id" => capability.mission_id,
      "workspace_id" => capability.workspace_id,
      "workspace_generation" => capability.workspace_generation,
      "fencing_generation" => capability.fencing_token
    }
  end
end
