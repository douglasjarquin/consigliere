defmodule Consigliere.RunnerIsolationTest do
  use ExUnit.Case, async: false

  alias Consigliere.{RunnerDynamicSupervisor, RunnerProcess}
  alias Consigliere.ProcessHelpers

  defp start_runner(attempt_id) do
    heartbeat_file =
      Path.join(System.tmp_dir!(), "runner-isolation-#{attempt_id}.hb")

    {:ok, pid} =
      DynamicSupervisor.start_child(
        RunnerDynamicSupervisor,
        {RunnerProcess, attempt_id: attempt_id, heartbeat_file: heartbeat_file}
      )

    {pid, heartbeat_file}
  end

  test "repeatedly crashing one runner's OS harness does not kill an unrelated runner" do
    {innocent_pid, innocent_heartbeat_file} = start_runner("isolation-innocent")
    innocent_os_pid = RunnerProcess.os_pid(innocent_pid)

    on_exit(fn ->
      if Process.alive?(innocent_pid) do
        DynamicSupervisor.terminate_child(RunnerDynamicSupervisor, innocent_pid)
      end

      ProcessHelpers.kill_and_verify_dead(innocent_os_pid)
      File.rm(innocent_heartbeat_file)
    end)

    {victim_pid, victim_heartbeat_file} = start_runner("isolation-victim")
    victim_os_pid = RunnerProcess.os_pid(victim_pid)

    on_exit(fn -> File.rm(victim_heartbeat_file) end)

    # RunnerProcess is restart: :temporary (Attempts are disposable, ADR-004),
    # so a single crash removes it from RunnerDynamicSupervisor's children
    # with no automatic respawn attempt at all -- there is no restart
    # intensity to exhaust. Kill it several times anyway to prove that even
    # repeated attempts against an already-gone child cannot destabilize the
    # supervisor or its unrelated sibling.
    for _ <- 1..5 do
      # Registry.lookup can return a pid whose GenServer is concurrently
      # dying (OS process gone, port's :exit_status not yet handled).
      # Process.alive? then GenServer.call is not atomic against that race,
      # so the call itself must be allowed to fail with :exit if the
      # process finishes terminating in between -- that is functionally
      # the same outcome as the [] (already gone) branch, not a real error.
      case Registry.lookup(Consigliere.Registry, {:runner, "isolation-victim"}) do
        [{pid, _}] ->
          try do
            ProcessHelpers.kill_and_verify_dead(RunnerProcess.os_pid(pid))
          catch
            :exit, _ -> :ok
          end

        [] ->
          :ok
      end

      Process.sleep(100)
    end

    assert Registry.lookup(Consigliere.Registry, {:runner, "isolation-victim"}) == [],
           "a :temporary RunnerProcess must not silently respawn under its own attempt_id after crashing"

    assert Process.alive?(innocent_pid),
           "innocent RunnerProcess BEAM pid died as collateral damage from an unrelated runner's repeated crashes"

    assert {_output, 0} = System.cmd("kill", ["-0", to_string(innocent_os_pid)]),
           "innocent OS harness process died as collateral damage from an unrelated runner's repeated crashes"

    refute victim_os_pid == innocent_os_pid
  end
end
