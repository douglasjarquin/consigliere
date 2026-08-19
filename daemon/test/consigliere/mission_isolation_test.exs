defmodule Consigliere.MissionIsolationTest do
  use ExUnit.Case, async: false

  alias Consigliere.MissionDynamicSupervisor

  defp start_test_mission(mission_id) do
    {:ok, mission_supervisor_pid} =
      MissionDynamicSupervisor.start_mission(
        mission_id: mission_id,
        attempt_id: "no-runner-#{mission_id}"
      )

    [{coordinator_pid, _}] = Registry.lookup(Consigliere.Registry, {:mission, mission_id})
    {mission_supervisor_pid, coordinator_pid}
  end

  test "repeatedly crashing one mission's coordinator does not kill an unrelated mission's coordinator" do
    innocent_mission_id = "isolation-innocent-mission-#{System.unique_integer([:positive])}"
    {innocent_supervisor_pid, innocent_pid} = start_test_mission(innocent_mission_id)

    victim_mission_id = "isolation-victim-mission-#{System.unique_integer([:positive])}"
    {victim_supervisor_pid, _victim_pid} = start_test_mission(victim_mission_id)

    on_exit(fn ->
      if Process.alive?(innocent_supervisor_pid) do
        DynamicSupervisor.terminate_child(MissionDynamicSupervisor, innocent_supervisor_pid)
      end

      if Process.alive?(victim_supervisor_pid) do
        DynamicSupervisor.terminate_child(MissionDynamicSupervisor, victim_supervisor_pid)
      end
    end)

    # 16 kills at ~100ms crosses not just the per-mission MissionSupervisor's
    # own restart-intensity threshold (3 restarts / 5s) but does so enough
    # times in a row to exhaust MissionDynamicSupervisor's OWN shared budget
    # too if a given-up mission subtree is ever blindly resurrected -- a
    # shallower loop only proved per-mission isolation, not the deeper
    # invariant that no number of one mission's crashes can ever cascade to
    # MissionDynamicSupervisor itself.
    for _ <- 1..16 do
      case Registry.lookup(Consigliere.Registry, {:mission, victim_mission_id}) do
        [{pid, _}] ->
          ref = Process.monitor(pid)
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
          after
            1_000 -> :ok
          end

        [] ->
          :ok
      end

      Process.sleep(100)
    end

    assert Process.alive?(innocent_pid),
           "innocent MissionCoordinator BEAM pid died as collateral damage from an unrelated mission's repeated crashes"

    assert Registry.lookup(Consigliere.Registry, {:mission, innocent_mission_id}) != [],
           "innocent mission's coordinator was removed from the registry as collateral damage"
  end
end
