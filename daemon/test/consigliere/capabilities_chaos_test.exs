defmodule Consigliere.CapabilitiesChaosTest do
  use ExUnit.Case, async: false

  import Ecto.Query

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

  test "corrupt durable scopes fail closed without leaking the raw secret" do
    attempt = running_attempt!()
    {:ok, secret} = Capabilities.mint(attempt)
    {:ok, capability} = Capabilities.authenticate(secret)

    assert {:ok, _} =
             Repo.update(
               AttemptCapability.changeset(capability, %{ops: %{"allow" => ["future.worker.op"]}})
             )

    assert {:error, "malformed capability"} = Capabilities.authenticate(secret)

    durable =
      Repo.all(from(e in Consigliere.DomainEvents.DomainEvent, select: e.payload))
      |> inspect()

    refute durable =~ secret
    refute durable =~ "future.worker.op"
  end

  test "revoke and a worker report converge without a post-revocation report" do
    attempt = running_attempt!()
    {:ok, secret} = Capabilities.mint(attempt)
    {:ok, capability} = Capabilities.authenticate(secret)
    actor = Auth.identify(%{"capability" => secret}, :capability)
    before = count_events("attempt.progress")

    tasks = [
      Task.async(fn -> Capabilities.revoke_for_attempt(attempt.id) end),
      Task.async(fn -> Attempts.report_progress(attempt.id, actor) end)
    ]

    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.any?(results, &match?({:ok, _}, &1))
    assert {:error, "revoked capability"} = Capabilities.authenticate(secret)
    assert (count_events("attempt.progress") - before) in [0, 1]

    stored = Repo.get!(AttemptCapability, capability.id)
    refute is_nil(stored.revoked_at)
  end

  test "terminal lifecycle transitions revoke worker authority" do
    attempt = running_attempt!()
    {:ok, secret} = Capabilities.mint(attempt)

    assert {:ok, _failed} =
             Attempts.fail(attempt.id, Actor.system(), %{process_group: :dead_verified})

    assert {:error, "revoked capability"} = Capabilities.authenticate(secret)
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

  defp count_events(type) do
    Repo.aggregate(
      from(e in Consigliere.DomainEvents.DomainEvent, where: e.type == ^type),
      :count
    )
  end
end
