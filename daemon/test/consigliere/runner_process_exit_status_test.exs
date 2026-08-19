defmodule Consigliere.RunnerProcessExitStatusTest do
  use ExUnit.Case, async: false

  alias Consigliere.RunnerProcess

  test "a clean exit (exit_status 0) stops the runner with reason :normal and deregisters it" do
    Process.flag(:trap_exit, true)

    heartbeat_file =
      Path.join(System.tmp_dir!(), "exit-status-clean-#{System.unique_integer([:positive])}.hb")

    attempt_id = "exit-status-clean-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      RunnerProcess.start_link(
        attempt_id: attempt_id,
        heartbeat_file: heartbeat_file,
        max_iterations: 2
      )

    on_exit(fn -> File.rm(heartbeat_file) end)

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    # Registry's own deregistration monitor is separate from ours and can
    # fire slightly after our :DOWN message arrives, so poll rather than
    # assert immediately.
    deregistered =
      Enum.reduce_while(1..20, false, fn _, _ ->
        if Registry.lookup(Consigliere.Registry, {:runner, attempt_id}) == [] do
          {:halt, true}
        else
          Process.sleep(50)
          {:cont, false}
        end
      end)

    assert deregistered, "runner was not deregistered from Registry after a clean exit"
  end

  test "a crash exit (nonzero exit_status) stops the runner with {:harness_exited, status}" do
    Process.flag(:trap_exit, true)

    heartbeat_file =
      Path.join(System.tmp_dir!(), "exit-status-crash-#{System.unique_integer([:positive])}.hb")

    attempt_id = "exit-status-crash-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      RunnerProcess.start_link(attempt_id: attempt_id, heartbeat_file: heartbeat_file)

    on_exit(fn -> File.rm(heartbeat_file) end)

    os_pid = RunnerProcess.os_pid(pid)
    ref = Process.monitor(pid)
    Consigliere.ProcessHelpers.kill_and_verify_dead(os_pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, {:harness_exited, 137}}, 2_000
  end
end
