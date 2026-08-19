defmodule Consigliere.SpikeBCoordinatorIndependenceTest do
  use ExUnit.Case, async: false

  alias Consigliere.RunnerDynamicSupervisor
  alias Consigliere.MissionDynamicSupervisor
  alias Consigliere.MissionCoordinator
  alias Consigliere.RunnerProcess

  setup do
    heartbeat_file =
      Path.join(System.tmp_dir!(), "spike-b-#{System.unique_integer([:positive])}.hb")

    attempt_id = "spike-b-attempt-#{System.unique_integer([:positive])}"
    mission_id = "spike-b-mission-#{System.unique_integer([:positive])}"

    {:ok, _runner_pid} =
      DynamicSupervisor.start_child(
        RunnerDynamicSupervisor,
        {RunnerProcess, attempt_id: attempt_id, heartbeat_file: heartbeat_file}
      )

    {:ok, mission_supervisor_pid} =
      MissionDynamicSupervisor.start_mission(mission_id: mission_id, attempt_id: attempt_id)

    [{coordinator_pid, _}] = Registry.lookup(Consigliere.Registry, {:mission, mission_id})

    on_exit(fn ->
      if Process.alive?(mission_supervisor_pid) do
        DynamicSupervisor.terminate_child(MissionDynamicSupervisor, mission_supervisor_pid)
      end

      case Registry.lookup(Consigliere.Registry, {:runner, attempt_id}) do
        [{runner_pid, _}] ->
          os_pid = RunnerProcess.os_pid(runner_pid)
          DynamicSupervisor.terminate_child(RunnerDynamicSupervisor, runner_pid)
          Consigliere.ProcessHelpers.kill_and_verify_dead(os_pid)

        [] ->
          :ok
      end

      File.rm(heartbeat_file)
    end)

    %{
      attempt_id: attempt_id,
      mission_id: mission_id,
      coordinator_pid: coordinator_pid,
      heartbeat_file: heartbeat_file
    }
  end

  test "killing MissionCoordinator does not terminate the RunnerProcess or its OS harness", %{
    attempt_id: attempt_id,
    coordinator_pid: coordinator_pid,
    heartbeat_file: heartbeat_file
  } do
    [{runner_pid, _}] = Registry.lookup(Consigliere.Registry, {:runner, attempt_id})
    os_pid = RunnerProcess.os_pid(runner_pid)

    runner_supervisor_children = DynamicSupervisor.which_children(RunnerDynamicSupervisor)
    mission_supervisor_children = DynamicSupervisor.which_children(MissionDynamicSupervisor)

    assert Enum.any?(runner_supervisor_children, fn {_, pid, _, _} -> pid == runner_pid end),
           "runner_pid must be a direct child of RunnerDynamicSupervisor"

    refute Enum.any?(mission_supervisor_children, fn {_, pid, _, _} -> pid == runner_pid end),
           "runner_pid must NOT be a child of MissionDynamicSupervisor (would defeat this invariant)"

    {:links, coordinator_links} = Process.info(coordinator_pid, :links)

    refute runner_pid in coordinator_links,
           "coordinator must not be linked to the runner (a link would cascade the kill)"

    Process.sleep(300)
    count_before = RunnerProcess.heartbeat_count(runner_pid)
    assert count_before > 0

    ref = Process.monitor(coordinator_pid)
    Process.exit(coordinator_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^coordinator_pid, :killed}, 1_000

    Process.sleep(300)

    assert Process.alive?(runner_pid)
    assert {_output, 0} = System.cmd("kill", ["-0", to_string(os_pid)])

    count_after = RunnerProcess.heartbeat_count(runner_pid)
    assert count_after > count_before

    assert File.exists?(heartbeat_file)
  end

  test "restarted MissionCoordinator re-attaches to the same still-running RunnerProcess", %{
    attempt_id: attempt_id,
    mission_id: mission_id,
    coordinator_pid: coordinator_pid
  } do
    [{runner_pid, _}] = Registry.lookup(Consigliere.Registry, {:runner, attempt_id})
    os_pid_before = RunnerProcess.os_pid(runner_pid)

    ref = Process.monitor(coordinator_pid)
    Process.exit(coordinator_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^coordinator_pid, :killed}, 1_000

    new_coordinator_pid =
      wait_until(fn ->
        case Registry.lookup(Consigliere.Registry, {:mission, mission_id}) do
          [{pid, _}] when pid != coordinator_pid -> pid
          _ -> nil
        end
      end)

    refute new_coordinator_pid == coordinator_pid

    reattached_runner_pid = MissionCoordinator.runner_pid(new_coordinator_pid)
    assert reattached_runner_pid == runner_pid
    assert RunnerProcess.os_pid(reattached_runner_pid) == os_pid_before

    count_before_check = RunnerProcess.heartbeat_count(reattached_runner_pid)
    Process.sleep(300)
    count_after_check = RunnerProcess.heartbeat_count(reattached_runner_pid)

    assert {_output, 0} = System.cmd("kill", ["-0", to_string(os_pid_before)]),
           "the OS harness must still be alive after coordinator reattachment, not merely reporting a cached pid"

    assert count_after_check > count_before_check,
           "the OS harness must still be producing heartbeats after coordinator reattachment"
  end

  defp wait_until(fun, attempts \\ 20) do
    case fun.() do
      nil when attempts > 0 ->
        Process.sleep(50)
        wait_until(fun, attempts - 1)

      nil ->
        flunk("condition never became true")

      value ->
        value
    end
  end
end
