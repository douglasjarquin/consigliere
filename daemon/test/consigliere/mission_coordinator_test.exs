defmodule Consigliere.MissionCoordinatorTest do
  use ExUnit.Case, async: false

  alias Consigliere.{MissionDynamicSupervisor, MissionCoordinator}

  test "looking up a runner for an unknown attempt_id returns :not_found without crashing" do
    mission_id = "orphan-mission-#{System.unique_integer([:positive])}"
    attempt_id = "nonexistent-attempt-#{System.unique_integer([:positive])}"

    {:ok, mission_supervisor_pid} =
      MissionDynamicSupervisor.start_mission(mission_id: mission_id, attempt_id: attempt_id)

    [{coordinator_pid, _}] = Registry.lookup(Consigliere.Registry, {:mission, mission_id})

    on_exit(fn ->
      if Process.alive?(mission_supervisor_pid) do
        DynamicSupervisor.terminate_child(MissionDynamicSupervisor, mission_supervisor_pid)
      end
    end)

    assert Process.alive?(coordinator_pid)
    assert MissionCoordinator.runner_pid(coordinator_pid) == :not_found
  end
end
