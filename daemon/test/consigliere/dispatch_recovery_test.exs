defmodule Consigliere.DispatchRecoveryTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Attempts.Attempt
  alias Consigliere.DatabaseWriter
  alias Consigliere.DispatchOperations
  alias Consigliere.DispatchOperations.DispatchOperation
  alias Consigliere.Fixtures
  alias Consigliere.GlobalScheduler
  alias Consigliere.API.Protocol
  alias Consigliere.MissionCoordinator
  alias Consigliere.MissionDynamicSupervisor
  alias Consigliere.Missions
  alias Consigliere.Missions.Transitions
  alias Consigliere.Repo
  alias Consigliere.Workspaces.Workspace

  setup do
    Fixtures.reset_phase1_tables!()
    GlobalScheduler.reset()
    :ok
  end

  test "grant work durably records one authorization, dispatch intent, workspace, and planned Attempt atomically" do
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())
    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())

    assert {:ok, authorized} =
             DatabaseWriter.transaction(fn ->
               mission =
                 Transitions.grant_work_authorization_with_dispatch_txn(
                   mission.id,
                   Actor.boss(),
                   %{correlation_id: "corr-1", idempotency_key: "grant-1"}
                 )

               attempts = Repo.all(from(a in Attempt, where: a.mission_id == ^mission.id))
               workspaces = Repo.all(from(w in Workspace, where: w.mission_id == ^mission.id))

               operations =
                 Repo.all(from(o in DispatchOperation, where: o.mission_id == ^mission.id))

               authorizations =
                 Repo.all(
                   from(a in Consigliere.Authorizations.Authorization,
                     where: a.mission_id == ^mission.id
                   )
                 )

               assert length(authorizations) == 1
               assert length(workspaces) == 1
               assert length(attempts) == 1
               assert length(operations) == 1

               [workspace] = workspaces
               [attempt] = attempts
               [operation] = operations
               assert attempt.status == "planned"
               assert operation.attempt_id == attempt.id
               assert operation.workspace_id == workspace.id
               assert operation.mission_id == mission.id
               assert operation.status == "pending"
               assert is_binary(Map.get(operation, :correlation_id))
               assert is_binary(Map.get(operation, :idempotency_key))
               assert Map.get(operation, :authorization_id) == mission.authorization_id
               assert Map.get(operation, :project_id) == mission.project_id
               assert Map.get(operation, :workspace_generation) == workspace.lease_id

               mission
             end)

    assert authorized.phase == "authorized"
  end

  test "duplicate grant request replays one durable dispatch identity" do
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())
    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())

    request = fn ->
      Protocol.handle(
        JSON.encode!(%{
          "v" => 1,
          "id" => "grant-request",
          "idempotency_key" => "grant-key",
          "op" => "mission.grant_work",
          "actor" => %{"principal" => "boss"},
          "payload" => %{"mission_id" => mission.id}
        })
      )
    end

    first = request.()
    second = request.()
    assert JSON.decode!(first) == JSON.decode!(second)

    assert Repo.aggregate(
             from(a in Consigliere.Authorizations.Authorization,
               where: a.mission_id == ^mission.id
             ),
             :count
           ) == 1

    assert Repo.aggregate(from(w in Workspace, where: w.mission_id == ^mission.id), :count) == 1
    assert Repo.aggregate(from(a in Attempt, where: a.mission_id == ^mission.id), :count) == 1

    assert Repo.aggregate(
             from(o in DispatchOperation, where: o.mission_id == ^mission.id),
             :count
           ) == 1
  end

  test "why exposes the durable dispatch boundary" do
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())
    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())

    {:ok, _} =
      DatabaseWriter.transaction(fn ->
        Transitions.grant_work_authorization_with_dispatch_txn(
          mission.id,
          Actor.boss(),
          %{correlation_id: "corr-why", idempotency_key: "grant-why"}
        )
      end)

    response =
      Protocol.handle(
        JSON.encode!(%{
          "v" => 1,
          "id" => "why-request",
          "op" => "mission.why",
          "actor" => %{"principal" => "boss"},
          "payload" => %{"mission_id" => mission.id}
        })
      )

    {:ok, decoded} = JSON.decode(response)
    dispatch = decoded["payload"]["dispatch"]
    assert dispatch["status"] == "pending"
    assert dispatch["correlation_id"] == "corr-why"
    assert dispatch["idempotency_key"] == "grant-why"
    assert dispatch["attempt_id"]
    assert dispatch["workspace_id"]
    assert dispatch["workspace_generation"]
  end

  test "an ambiguous starting Attempt becomes unknown and is never redispatched" do
    {:ok, mission} = submitted_mission()

    {:ok, _} =
      DatabaseWriter.transaction(fn ->
        Transitions.grant_work_authorization_with_dispatch_txn(
          mission.id,
          Actor.boss(),
          %{correlation_id: "corr-unknown", idempotency_key: "grant-unknown"}
        )
      end)

    attempt = Repo.get_by!(Attempt, mission_id: mission.id)
    operation = DispatchOperations.get_by_attempt(attempt.id)
    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())

    {:ok, _} =
      DispatchOperations.update(operation, %{
        status: "spawn_requested",
        child_start_state: "unknown"
      })

    {:ok, supervisor_pid} = MissionDynamicSupervisor.start_mission(mission_id: mission.id)

    on_exit(fn ->
      if Process.alive?(supervisor_pid) do
        DynamicSupervisor.terminate_child(MissionDynamicSupervisor, supervisor_pid)
      end
    end)

    await_until(fn -> DispatchOperations.get_by_attempt(attempt.id).status == "unknown" end)

    assert MissionCoordinator.snapshot(coordinator_pid(mission.id)).reason == :unknown
    assert Registry.lookup(Consigliere.Registry, {:runner, attempt.id}) == []
    assert Repo.get!(Attempt, attempt.id).status == "starting"
    assert Repo.aggregate(from(a in Attempt, where: a.mission_id == ^mission.id), :count) == 1

    assert Repo.aggregate(
             from(o in DispatchOperation, where: o.mission_id == ^mission.id),
             :count
           ) == 1
  end

  test "a terminal Attempt prevents a second dispatch" do
    {:ok, mission} = submitted_mission()

    {:ok, _} =
      DatabaseWriter.transaction(fn ->
        Transitions.grant_work_authorization_with_dispatch_txn(
          mission.id,
          Actor.boss(),
          %{correlation_id: "corr-terminal", idempotency_key: "grant-terminal"}
        )
      end)

    attempt = Repo.get_by!(Attempt, mission_id: mission.id)
    operation = DispatchOperations.get_by_attempt(attempt.id)
    assert {:ok, _failed} = Attempts.mark_spawn_failed(attempt.id, Actor.system(), "fixture")
    assert {:ok, _} = DispatchOperations.update(operation, %{status: "failed"})

    {:ok, supervisor_pid} = MissionDynamicSupervisor.start_mission(mission_id: mission.id)

    on_exit(fn ->
      if Process.alive?(supervisor_pid) do
        DynamicSupervisor.terminate_child(MissionDynamicSupervisor, supervisor_pid)
      end
    end)

    Process.sleep(100)
    assert Registry.lookup(Consigliere.Registry, {:runner, attempt.id}) == []
    assert Repo.aggregate(from(a in Attempt, where: a.mission_id == ^mission.id), :count) == 1
    assert Repo.get!(Attempt, attempt.id).status == "failed"
    assert MissionCoordinator.snapshot(coordinator_pid(mission.id)).reason == :dispatch_failed
  end

  test "one active Mission per Project rejects a second authorization" do
    project = Fixtures.dummy_project!()
    attrs = %{objective: "o", scope: "s", acceptance_criteria: "a", project_id: project.id}
    {:ok, first} = Missions.create(attrs, Actor.boss())
    {:ok, first} = Missions.submit_for_authorization(first.id, Actor.boss())

    {:ok, _authorized} =
      DatabaseWriter.transaction(fn ->
        Transitions.grant_work_authorization_with_dispatch_txn(
          first.id,
          Actor.boss(),
          %{correlation_id: "corr-first", idempotency_key: "grant-first"}
        )
      end)

    {:ok, second} = Missions.create(attrs, Actor.boss())
    {:ok, second} = Missions.submit_for_authorization(second.id, Actor.boss())

    assert {:error, {:illegal_transition, %{reason: :project_busy}}} =
             DatabaseWriter.transaction(fn ->
               Transitions.grant_work_authorization_with_dispatch_txn(
                 second.id,
                 Actor.boss(),
                 %{correlation_id: "corr-second", idempotency_key: "grant-second"}
               )
             end)

    assert Repo.get!(Consigliere.Missions.Mission, second.id).phase == "awaiting_authorization"

    assert Repo.aggregate(
             from(a in Consigliere.Authorizations.Authorization,
               where: a.mission_id == ^second.id
             ),
             :count
           ) == 0

    assert Repo.aggregate(from(a in Attempt, where: a.mission_id == ^second.id), :count) == 0
  end

  test "duplicate coordinator wakeups keep one live runner and one durable Attempt" do
    {:ok, mission} = submitted_mission()

    {:ok, _} =
      DatabaseWriter.transaction(fn ->
        Transitions.grant_work_authorization_with_dispatch_txn(
          mission.id,
          Actor.boss(),
          %{correlation_id: "corr-wakeup", idempotency_key: "grant-wakeup"}
        )
      end)

    {:ok, first_supervisor} = MissionDynamicSupervisor.start_mission(mission_id: mission.id)
    {:ok, second_supervisor} = MissionDynamicSupervisor.start_mission(mission_id: mission.id)
    assert first_supervisor == second_supervisor

    on_exit(fn ->
      if Process.alive?(first_supervisor) do
        DynamicSupervisor.terminate_child(MissionDynamicSupervisor, first_supervisor)
      end
    end)

    coordinator = coordinator_pid(mission.id)
    await_until(fn -> is_pid(MissionCoordinator.snapshot(coordinator).runner_pid) end)
    snapshot = MissionCoordinator.snapshot(coordinator)

    assert length(Registry.lookup(Consigliere.Registry, {:runner, snapshot.attempt_id})) == 1
    assert Repo.aggregate(from(a in Attempt, where: a.mission_id == ^mission.id), :count) == 1

    assert Repo.aggregate(
             from(o in DispatchOperation, where: o.mission_id == ^mission.id),
             :count
           ) == 1
  end

  test "a second planned dispatch stays authorized while the V0 slot is occupied" do
    {:ok, first} = submitted_mission()
    {:ok, second} = submitted_mission()

    for mission <- [first, second] do
      {:ok, _} =
        DatabaseWriter.transaction(fn ->
          Transitions.grant_work_authorization_with_dispatch_txn(
            mission.id,
            Actor.boss(),
            %{correlation_id: "corr-#{mission.id}", idempotency_key: "grant-#{mission.id}"}
          )
        end)
    end

    {:ok, first_supervisor} = MissionDynamicSupervisor.start_mission(mission_id: first.id)
    first_coordinator = coordinator_pid(first.id)
    await_until(fn -> is_pid(MissionCoordinator.snapshot(first_coordinator).runner_pid) end)

    {:ok, second_supervisor} = MissionDynamicSupervisor.start_mission(mission_id: second.id)
    second_coordinator = coordinator_pid(second.id)

    on_exit(fn ->
      for supervisor_pid <- [first_supervisor, second_supervisor] do
        if Process.alive?(supervisor_pid) do
          DynamicSupervisor.terminate_child(MissionDynamicSupervisor, supervisor_pid)
        end
      end
    end)

    await_until(fn -> MissionCoordinator.snapshot(second_coordinator).reason == :capacity end)
    assert Repo.get!(Consigliere.Missions.Mission, second.id).phase == "authorized"
    assert Repo.aggregate(from(a in Attempt, where: a.mission_id == ^second.id), :count) == 1
    assert Registry.lookup(Consigliere.Registry, {:runner, second.id}) == []
  end

  defp submitted_mission do
    with {:ok, mission} <- Missions.create(Fixtures.mission_attrs(), Actor.boss()),
         {:ok, mission} <- Missions.submit_for_authorization(mission.id, Actor.boss()) do
      {:ok, mission}
    end
  end

  defp coordinator_pid(mission_id) do
    case Registry.lookup(Consigliere.Registry, {:mission, mission_id}) do
      [{pid, _}] -> pid
      [] -> flunk("coordinator never started for #{mission_id}")
    end
  end

  defp await_until(fun, remaining \\ 100) do
    cond do
      fun.() ->
        :ok

      remaining <= 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(50)
        await_until(fun, remaining - 1)
    end
  end
end
