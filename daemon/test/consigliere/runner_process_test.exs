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

  test "captures authenticated harness stderr frames", %{heartbeat_file: heartbeat_file} do
    attempt_id = "attempt-stderr-#{System.unique_integer([:positive])}"
    log_path = Path.join(Consigliere.Home.logs_dir(), "attempts/#{attempt_id}.log")

    {:ok, pid} =
      RunnerProcess.start_link(
        attempt_id: attempt_id,
        heartbeat_file: heartbeat_file,
        harness_command: ["sh", "-c", "printf 'stderr-from-harness\\n' >&2; sleep 5"]
      )

    os_pid = RunnerProcess.os_pid(pid)

    on_exit(fn ->
      Consigliere.ProcessHelpers.kill_and_verify_dead(os_pid)
      File.rm(log_path)
    end)

    wait_for_file(log_path)
    assert File.read!(log_path) =~ "stderr-from-harness"
  end

  defp wait_for_file(path, attempts \\ 100) do
    cond do
      File.exists?(path) ->
        :ok

      attempts > 0 ->
        Process.sleep(50)
        wait_for_file(path, attempts - 1)

      true ->
        flunk("capture file missing: #{path}")
    end
  end
end
