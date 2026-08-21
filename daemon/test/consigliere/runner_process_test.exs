defmodule Consigliere.RunnerProcessTest do
  use ExUnit.Case, async: false

  alias Consigliere.RunnerProcess

  setup do
    heartbeat_file =
      Path.join(System.tmp_dir!(), "runner-process-test-#{System.unique_integer([:positive])}.hb")

    on_exit(fn -> File.rm(heartbeat_file) end)
    {:ok, heartbeat_file: heartbeat_file}
  end

  test "spawns a fake harness process and heartbeats keep flowing", %{
    heartbeat_file: heartbeat_file
  } do
    attempt_id = "attempt-runner-#{System.unique_integer([:positive])}"
    {:ok, pid} = RunnerProcess.start_link(attempt_id: attempt_id, heartbeat_file: heartbeat_file)

    os_pid = RunnerProcess.os_pid(pid)
    on_exit(fn -> Consigliere.ProcessHelpers.kill_and_verify_dead(os_pid) end)

    assert is_integer(os_pid)
    assert os_pid > 0

    Process.sleep(800)

    assert File.exists?(heartbeat_file)
    [pid_str, _count_str] = heartbeat_file |> File.read!() |> String.trim() |> String.split(" ")
    assert String.to_integer(pid_str) == os_pid

    assert RunnerProcess.heartbeat_count(pid) > 0
  end
end
