defmodule Consigliere.MissionCoordinatorRehydrateTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Attempts.Attempt
  alias Consigliere.EventBus
  alias Consigliere.Fixtures
  alias Consigliere.GlobalScheduler
  alias Consigliere.MissionCoordinator
  alias Consigliere.MissionDynamicSupervisor
  alias Consigliere.Missions
  alias Consigliere.Missions.Mission
  alias Consigliere.MissionBlockers.MissionBlocker
  alias Consigliere.Repo

  setup do
    Fixtures.reset_phase1_tables!()
    GlobalScheduler.reset()
    :ok
  end

  defp start_coord!(mission_id) do
    {:ok, supervisor_pid} =
      MissionDynamicSupervisor.start_mission(mission_id: mission_id)

    [{coordinator_pid, _}] = Registry.lookup(Consigliere.Registry, {:mission, mission_id})

    on_exit(fn ->
      if Process.alive?(supervisor_pid) do
        DynamicSupervisor.terminate_child(MissionDynamicSupervisor, supervisor_pid)
      end

      GlobalScheduler.release_slot(mission_id)
    end)

    coordinator_pid
  end

  defp authorized_mission! do
    {:ok, mission} =
      Missions.create(Fixtures.mission_attrs(), Actor.boss())

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Missions.grant_work_authorization(mission.id, Actor.boss())
    mission
  end

  test "rehydrates phase and blockers from projections, not the event log" do
    mission = authorized_mission!()

    {:ok, _} =
      Repo.insert(
        MissionBlocker.changeset(%MissionBlocker{}, %{
          mission_id: mission.id,
          kind: "question",
          reason: "waiting",
          status: "open"
        })
      )

    pid = start_coord!(mission.id)
    snap = MissionCoordinator.evaluate(pid)

    assert snap.phase == "authorized"
    assert snap.runnable == false
    assert snap.reason == :blocked
    assert snap.blockers == 1
    assert Repo.get!(Mission, mission.id).phase == "authorized"
  end

  test "an authorized mission with no blockers takes the slot and starts an Attempt" do
    mission = authorized_mission!()
    pid = start_coord!(mission.id)
    await_until(fn -> Repo.get!(Mission, mission.id).phase == "active" end)
    snap = MissionCoordinator.snapshot(pid)

    assert snap.runnable == true or snap.reason == :occupying
    reloaded = Repo.get!(Mission, mission.id)
    assert reloaded.phase == "active"
    assert reloaded.started_at
    assert snap.attempt_id
    assert mission.id in GlobalScheduler.occupants()
  end

  test "global concurrency of 1 leaves the second authorized mission waiting on capacity" do
    first = authorized_mission!()
    second = authorized_mission!()

    _pid1 = start_coord!(first.id)
    await_until(fn -> Repo.get!(Mission, first.id).phase == "active" end)

    pid2 = start_coord!(second.id)
    await_until(fn -> MissionCoordinator.snapshot(pid2).reason == :capacity end)
    snap2 = MissionCoordinator.snapshot(pid2)
    assert snap2.reason == :capacity
    assert Repo.get!(Mission, second.id).phase == "authorized"
  end

  test "a mission.authorized event re-evaluates a waiting coordinator" do
    {:ok, mission} =
      Missions.create(Fixtures.mission_attrs(), Actor.boss())

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    pid = start_coord!(mission.id)
    snap = MissionCoordinator.evaluate(pid)
    assert snap.reason == :phase

    {:ok, _} = Missions.grant_work_authorization(mission.id, Actor.boss())
    EventBus.poll()

    snap =
      Enum.reduce_while(1..20, nil, fn _, _ ->
        s = MissionCoordinator.snapshot(pid)

        if Repo.get!(Mission, mission.id).phase == "active" do
          {:halt, s}
        else
          Process.sleep(20)
          {:cont, s}
        end
      end)

    assert Repo.get!(Mission, mission.id).phase == "active"
    assert snap.attempt_id
  end

  test "killing the coordinator does not require a RunnerProcess and rehydrates the same phase" do
    mission = authorized_mission!()
    pid = start_coord!(mission.id)

    await_until(fn ->
      Repo.get!(Mission, mission.id).phase == "active" and
        Repo.get_by!(Attempt, mission_id: mission.id).status == "running"
    end)

    assert Repo.get!(Mission, mission.id).phase == "active"

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

    new_pid =
      Enum.reduce_while(1..20, nil, fn _, _ ->
        case Registry.lookup(Consigliere.Registry, {:mission, mission.id}) do
          [{p, _}] when p != pid ->
            {:halt, p}

          _ ->
            Process.sleep(20)
            {:cont, nil}
        end
      end)

    snap = MissionCoordinator.evaluate(new_pid)
    assert snap.phase == "active"
    assert snap.reason in [:occupying, :recover]
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
