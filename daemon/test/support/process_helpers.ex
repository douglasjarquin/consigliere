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
    pid_path =
      Path.join(
        System.tmp_dir!(),
        "consigliere-session-leader-#{System.unique_integer([:positive, :monotonic])}.pid"
      )

    {executable, args} =
      case System.find_executable("setsid") do
        nil ->
          ruby =
            System.find_executable("ruby") ||
              System.find_executable("ruby3") ||
              raise("ruby is required to spawn a setsid process group")

          script = """
          Process.daemon(true, false)
          File.write(ARGV.fetch(0), Process.pid.to_s)
          sleep 60
          """

          {ruby, ["-e", script, pid_path]}

        setsid ->
          shell =
            System.find_executable("sh") ||
              raise("sh is required to spawn a setsid process group")

          {setsid, [shell, "-c", ~S[echo "$$" > "$1"; exec sleep 60], "sh", pid_path]}
      end

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        args: args
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
        raise "process group #{pgid} is still alive: #{group_diagnostic(pgid)}"
    end
  end

  defp group_diagnostic(pgid) do
    {ps_output, ps_status} =
      System.cmd("ps", ["-axo", "pid=,ppid=,pgid=,sid=,stat=,comm=,args="],
        stderr_to_stdout: true
      )

    members =
      ps_output
      |> String.split("\n", trim: true)
      |> Enum.filter(fn line ->
        case String.split(String.trim(line), ~r/\s+/, parts: 4) do
          [_, _, group, _] -> group == to_string(pgid)
          _ -> false
        end
      end)

    {probe_output, probe_status} =
      System.cmd("kill", ["-0", "--", "-#{pgid}"], stderr_to_stdout: true)

    inspect(%{
      members: members,
      probe: {probe_status, String.trim(probe_output)},
      ps_status: ps_status
    })
  end

  defp wait_session_leader!(pid) do
    expected_leader = to_string(pid)

    Enum.reduce_while(1..50, :error, fn _, _ ->
      {out, 0} =
        System.cmd("ps", ["-o", "pgid=,sid=", "-p", to_string(pid)], stderr_to_stdout: true)

      case String.split(String.trim(out)) do
        [leader, leader] when leader == expected_leader ->
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
