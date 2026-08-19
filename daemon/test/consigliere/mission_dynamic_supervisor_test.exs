defmodule Consigliere.MissionDynamicSupervisorTest do
  use ExUnit.Case, async: false

  alias Consigliere.{MissionDynamicSupervisor, MissionCoordinator}

  test "start_mission/1 is the one sanctioned way to start a mission subtree" do
    mission_id = "sanctioned-start-#{System.unique_integer([:positive])}"
    attempt_id = "no-runner-#{mission_id}"

    {:ok, mission_supervisor_pid} =
      MissionDynamicSupervisor.start_mission(mission_id: mission_id, attempt_id: attempt_id)

    on_exit(fn ->
      if Process.alive?(mission_supervisor_pid) do
        DynamicSupervisor.terminate_child(MissionDynamicSupervisor, mission_supervisor_pid)
      end
    end)

    [{coordinator_pid, _}] = Registry.lookup(Consigliere.Registry, {:mission, mission_id})
    assert Process.alive?(coordinator_pid)
    assert MissionCoordinator.runner_pid(coordinator_pid) == :not_found

    assert Enum.any?(
             DynamicSupervisor.which_children(MissionDynamicSupervisor),
             fn {_, pid, _, _} -> pid == mission_supervisor_pid end
           )
  end

  test "MissionSupervisor is registered as a :supervisor child, not :worker" do
    mission_id = "type-check-#{System.unique_integer([:positive])}"
    attempt_id = "no-runner-#{mission_id}"

    {:ok, mission_supervisor_pid} =
      MissionDynamicSupervisor.start_mission(mission_id: mission_id, attempt_id: attempt_id)

    on_exit(fn ->
      if Process.alive?(mission_supervisor_pid) do
        DynamicSupervisor.terminate_child(MissionDynamicSupervisor, mission_supervisor_pid)
      end
    end)

    assert Enum.any?(
             DynamicSupervisor.which_children(MissionDynamicSupervisor),
             fn {_, pid, type, _} -> pid == mission_supervisor_pid and type == :supervisor end
           ),
           "MissionSupervisor must be registered as a :supervisor child (needed for correct shutdown semantics), not :worker"
  end
end
