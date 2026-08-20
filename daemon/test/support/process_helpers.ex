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

    pid_path =
      Path.join(
        System.tmp_dir!(),
        "consigliere-session-leader-#{System.unique_integer([:positive, :monotonic])}.pid"
      )

    script = """
    Process.daemon(true, false)
    File.write(ARGV.fetch(0), Process.pid.to_s)
    sleep 60
    """

    port =
      Port.open({:spawn_executable, ruby}, [
        :binary,
        :exit_status,
        args: ["-e", script, pid_path]
      ])

    pid = wait_session_leader_pid!(pid_path)
    File.rm(pid_path)
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

  defp wait_session_leader_pid!(path, attempts \\ 50) do
    case File.read(path) do
      {:ok, contents} ->
        case Integer.parse(String.trim(contents)) do
          {pid, ""} -> pid
          _ -> retry_session_leader_pid!(path, attempts)
        end

      {:error, _} ->
        retry_session_leader_pid!(path, attempts)
    end
  end

  defp retry_session_leader_pid!(path, attempts) when attempts > 0 do
    Process.sleep(20)
    wait_session_leader_pid!(path, attempts - 1)
  end

  defp retry_session_leader_pid!(path, 0) do
    raise "session leader pid file #{path} was not written"
  end
end
