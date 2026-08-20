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

  def spawn_session_leader do
    ruby =
      System.find_executable("ruby") ||
        System.find_executable("ruby3") ||
        raise("ruby is required to spawn a setsid process group")

    port =
      Port.open({:spawn_executable, ruby}, [
        :binary,
        :exit_status,
        args: ["-e", "Process.setsid; sleep 60"]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    wait_session_leader!(pid)
    {port, pid}
  end

  def wait_group_gone(pgid, attempts \\ 40) do
    cond do
      Consigliere.ProcessGroup.gone?(pgid) ->
        :ok

      attempts > 0 ->
        Process.sleep(50)
        wait_group_gone(pgid, attempts - 1)

      true ->
        raise "process group #{pgid} is still alive"
    end
  end

  defp wait_session_leader!(pid) do
    Enum.reduce_while(1..50, :error, fn _, _ ->
      {out, 0} = System.cmd("ps", ["-o", "pgid=", "-p", to_string(pid)], stderr_to_stdout: true)

      case Integer.parse(String.trim(out)) do
        {pgid, _} when pgid == pid ->
          {:halt, :ok}

        _ ->
          Process.sleep(20)
          {:cont, :error}
      end
    end)
    |> case do
      :ok -> :ok
      :error -> raise "pid #{pid} never became its own session leader"
    end
  end
end
