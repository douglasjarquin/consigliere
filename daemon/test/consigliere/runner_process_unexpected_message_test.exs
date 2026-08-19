defmodule Consigliere.RunnerProcessUnexpectedMessageTest do
  use ExUnit.Case, async: false

  alias Consigliere.RunnerProcess

  test "an unexpected message does not crash the runner" do
    heartbeat_file =
      Path.join(System.tmp_dir!(), "unexpected-msg-#{System.unique_integer([:positive])}.hb")

    attempt_id = "unexpected-msg-#{System.unique_integer([:positive])}"

    {:ok, pid} = RunnerProcess.start_link(attempt_id: attempt_id, heartbeat_file: heartbeat_file)

    on_exit(fn ->
      if Process.alive?(pid) do
        os_pid = RunnerProcess.os_pid(pid)
        Consigliere.ProcessHelpers.kill_and_verify_dead(os_pid)
      end

      File.rm(heartbeat_file)
    end)

    send(pid, :some_unexpected_message)
    Process.sleep(100)

    assert Process.alive?(pid)
    assert RunnerProcess.os_pid(pid) |> is_integer()
  end
end
