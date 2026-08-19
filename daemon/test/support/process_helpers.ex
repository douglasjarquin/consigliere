defmodule Consigliere.ProcessHelpers do
  def kill_and_verify_dead(os_pid, attempts \\ 20) do
    System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)
    wait_until_dead(os_pid, attempts)
  end

  def wait_until_dead(os_pid, attempts) do
    case System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} when attempts > 0 ->
        Process.sleep(50)
        wait_until_dead(os_pid, attempts - 1)

      {_, 0} ->
        raise "os pid #{os_pid} never died after repeated kill -9"

      _ ->
        :ok
    end
  end
end
