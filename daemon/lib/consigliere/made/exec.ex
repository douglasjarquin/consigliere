defmodule Consigliere.Made.Exec do
  @moduledoc """
  Contained Made invocation: new session, isolated env, bounded capture,
  timeout, then verified death.
  """

  alias Consigliere.ProcessGroup

  @default_timeout_ms 30_000
  @max_output 65_536

  def run(binary, args, env, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    setsid = setsid_path()
    env_bin = System.find_executable("env") || "/usr/bin/env"
    env_args = ["-i" | Enum.map(env, fn {k, v} -> "#{k}=#{v}" end)] ++ [binary | args]

    port =
      Port.open({:spawn_executable, setsid}, [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        args: [env_bin | env_args]
      ])

    os_pid = Keyword.get(Port.info(port), :os_pid)
    collect(port, os_pid, deadline(timeout), [])
  end

  def setsid_path do
    :filename.join(:code.priv_dir(:consigliere_daemon), ~c"cs_setsid") |> List.to_string()
  end

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms

  defp collect(port, os_pid, deadline, acc) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        acc = [acc, data]

        if IO.iodata_length(acc) > @max_output do
          kill(os_pid, port)
          {:error, :output_too_large, IO.iodata_to_binary(acc), os_pid}
        else
          collect(port, os_pid, deadline, acc)
        end

      {^port, {:exit_status, status}} ->
        output = IO.iodata_to_binary(acc)
        death = verify(os_pid)

        if death == :dead_verified do
          {:ok, output, status, os_pid}
        else
          kill(os_pid, port)
          {:error, :death_unverified, output, os_pid}
        end
    after
      wait ->
        kill(os_pid, port)
        {:error, :timeout, IO.iodata_to_binary(acc), os_pid}
    end
  end

  defp verify(pid) when is_integer(pid) and pid > 1 do
    if ProcessGroup.gone?(pid), do: :dead_verified, else: ProcessGroup.terminate(pid)
  end

  defp verify(_), do: :dead_unverified

  defp kill(pid, port) do
    if is_integer(pid) and pid > 1, do: ProcessGroup.terminate(pid)
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end
end
