defmodule Consigliere.GlobalSchedulerTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.DatabaseWriter
  alias Consigliere.DispatchOperations
  alias Consigliere.DispatchOperations.DispatchOperation
  alias Consigliere.Fixtures
  alias Consigliere.GlobalScheduler
  alias Consigliere.Missions
  alias Consigliere.Missions.Transitions
  alias Consigliere.Repo
  alias Consigliere.Attempts

  setup do
    Fixtures.reset_phase1_tables!()
    GlobalScheduler.reset()
    :ok
  end

  test "grants one slot and refuses a second until release" do
    assert {:ok, :granted} = GlobalScheduler.request_slot("m1")
    assert {:ok, :held} = GlobalScheduler.request_slot("m1")
    assert {:error, :busy} = GlobalScheduler.request_slot("m2")
    assert :ok = GlobalScheduler.release_slot("m1")
    assert {:ok, :granted} = GlobalScheduler.request_slot("m2")
  end

  test "a restarted scheduler rebuilds occupancy from occupying Attempt rows" do
    {:ok, mission} =
      Missions.create(Fixtures.mission_attrs(), Actor.boss())

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Fixtures.grant_work_quietly(mission.id, Actor.boss())

    {:ok, %{attempt: attempt}} =
      Missions.start(mission.id, Actor.system(), %{
        workspace_path: "/tmp/cs-#{System.unique_integer([:positive])}"
      })

    {:ok, _} = Attempts.request_spawn(attempt.id, Actor.system())
    {:ok, _operation} = DispatchOperations.ensure(attempt, %{slot_state: "unknown"})

    pid = Process.whereis(GlobalScheduler)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

    new_pid =
      Enum.reduce_while(1..50, nil, fn _, _ ->
        case Process.whereis(GlobalScheduler) do
          p when is_pid(p) and p != pid ->
            {:halt, p}

          _ ->
            Process.sleep(10)
            {:cont, nil}
        end
      end)

    assert is_pid(new_pid)
    assert mission.id in GlobalScheduler.occupants()
    assert {:error, :busy} = GlobalScheduler.request_slot(Ecto.UUID.generate())
  end

  test "a scheduler rebuild keeps an unreleased dispatch slot occupied" do
    {:ok, mission} =
      Missions.create(Fixtures.mission_attrs(), Actor.boss())

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Fixtures.grant_work_quietly(mission.id, Actor.boss())

    {:ok, %{attempt: attempt}} =
      Missions.start(mission.id, Actor.system(), %{
        workspace_path: "/tmp/cs-#{System.unique_integer([:positive])}"
      })

    {:ok, _} = Attempts.request_spawn(attempt.id, Actor.system())
    {:ok, _operation} = DispatchOperations.ensure(attempt, %{slot_state: "granted"})

    assert :ok = GlobalScheduler.release_slot(attempt.mission_id)
    assert :ok = GlobalScheduler.reset()
    assert mission.id in GlobalScheduler.occupants()
    assert {:error, :busy} = GlobalScheduler.request_slot(Ecto.UUID.generate())
  end

  test "canceling a planned dispatch releases its durable slot before rebuild" do
    {:ok, mission} =
      Missions.create(Fixtures.mission_attrs(), Actor.boss())

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())

    {:ok, mission} =
      DatabaseWriter.transaction(fn ->
        Transitions.grant_work_authorization_with_dispatch_txn(
          mission.id,
          Actor.boss(),
          %{correlation_id: "corr-planned-cancel", idempotency_key: "planned-cancel"}
        )
      end)

    attempt = Repo.get_by!(Consigliere.Attempts.Attempt, mission_id: mission.id)

    assert %DispatchOperation{slot_state: "pending"} =
             DispatchOperations.get_by_attempt(attempt.id)

    assert :ok = GlobalScheduler.reset()
    assert mission.id in GlobalScheduler.occupants()

    assert {:ok, %{phase: "canceled"}} =
             Missions.cancel(mission.id, Actor.boss(), "operator stop")

    assert Repo.get!(Consigliere.Attempts.Attempt, attempt.id).status == "canceled"
    assert DispatchOperations.get_by_attempt(attempt.id).slot_state == "released"

    assert {:ok, :granted} = GlobalScheduler.request_slot(Ecto.UUID.generate())
    assert :ok = GlobalScheduler.reset()
    assert {:ok, :granted} = GlobalScheduler.request_slot(Ecto.UUID.generate())
  end
end
