defmodule Consigliere.DispatchTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Fixtures
  alias Consigliere.GlobalScheduler
  alias Consigliere.MissionCoordinator
  alias Consigliere.MissionDynamicSupervisor
  alias Consigliere.Missions
  alias Consigliere.Repo

  setup do
    Fixtures.reset_phase1_tables!()
    GlobalScheduler.reset()
    :ok
  end

  test "a coordinator on an authorized Mission starts a RunnerProcess" do
    {:ok, mission} =
      Missions.create(Fixtures.mission_attrs(), Actor.boss())

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Missions.grant_work_authorization(mission.id, Actor.boss())

    {:ok, sup} = MissionDynamicSupervisor.start_mission(mission_id: mission.id)

    on_exit(fn ->
      case Registry.lookup(Consigliere.Registry, {:mission, mission.id}) do
        [{coord, _}] ->
          case MissionCoordinator.runner_pid(coord) do
            pid when is_pid(pid) -> Consigliere.RunnerProcess.cancel(pid)
            _ -> :ok
          end

        _ ->
          :ok
      end

      if Process.alive?(sup) do
        DynamicSupervisor.terminate_child(MissionDynamicSupervisor, sup)
      end
    end)

    [{coord, _}] = Registry.lookup(Consigliere.Registry, {:mission, mission.id})
    snapshot = await_runner(coord)
    assert is_pid(snapshot.runner_pid)

    attempt = Repo.get_by(Attempt, mission_id: mission.id)
    assert attempt
    assert attempt.status in ["starting", "running"]
    assert Registry.lookup(Consigliere.Registry, {:runner, attempt.id}) != []
  end

  test "canceling a running Mission cancels its RunnerProcess" do
    {:ok, mission} =
      Missions.create(Fixtures.mission_attrs(), Actor.boss())

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Missions.grant_work_authorization(mission.id, Actor.boss())
    {:ok, sup} = MissionDynamicSupervisor.start_mission(mission_id: mission.id)
    [{coord, _}] = Registry.lookup(Consigliere.Registry, {:mission, mission.id})
    snapshot = await_runner(coord)
    runner = snapshot.runner_pid
    assert is_pid(runner)
    ref = Process.monitor(runner)

    assert {:ok, _} = Missions.cancel(mission.id, Actor.boss(), "stop")
    assert_receive {:DOWN, ^ref, :process, ^runner, _}, 5_000
    _ = DynamicSupervisor.terminate_child(MissionDynamicSupervisor, sup)
  end

  defp await_runner(coord, remaining \\ 100) do
    snap = MissionCoordinator.snapshot(coord)

    cond do
      is_pid(snap.runner_pid) ->
        snap

      remaining <= 0 ->
        snap

      true ->
        Process.sleep(50)
        await_runner(coord, remaining - 1)
    end
  end
end
