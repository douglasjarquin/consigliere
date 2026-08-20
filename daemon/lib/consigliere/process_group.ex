defmodule Consigliere.ProcessGroup do
  @moduledoc """
  Adopt-and-kill: SIGTERM, bounded wait, SIGKILL, bounded verify.
  Matches docs/protocols/runner.md termination sequence. Never signals
  pgid 0/1 (POSIX broadcast).

  Linux keeps unreaped children as zombies, and `kill -0` succeeds on a
  zombie. Zombies cannot run, so they count as gone.
  """

  def terminate(pgid, opts \\ [])

  def terminate(pgid, _opts) when not is_integer(pgid) or pgid <= 1 do
    :dead_unverified
  end

  def terminate(pgid, opts) do
    term_ms = Keyword.get(opts, :term_timeout_ms, 5_000)
    kill_ms = Keyword.get(opts, :kill_timeout_ms, 2_000)

    _ = signal(pgid, "-TERM")

    cond do
      wait_gone(pgid, term_ms) ->
        :dead_verified

      true ->
        _ = signal(pgid, "-KILL")
        if wait_gone(pgid, kill_ms), do: :dead_verified, else: :dead_unverified
    end
  end

  def alive?(pgid) when is_integer(pgid) and pgid > 1 do
    case runnable_members(pgid) do
      {:ok, []} -> false
      {:ok, _} -> true
      :error -> kill_probe_alive?(pgid)
    end
  end

  def alive?(_), do: false

  def gone?(pgid), do: not alive?(pgid)

  defp signal(pgid, sig) do
    System.cmd("kill", [sig, "-#{pgid}"], stderr_to_stdout: true)
  rescue
    _ -> {"", 1}
  end

  defp wait_gone(pgid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(pgid, deadline)
  end

  defp do_wait(pgid, deadline) do
    if gone?(pgid) do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(20)
        do_wait(pgid, deadline)
      end
    end
  end

  defp runnable_members(pgid) do
    case System.cmd("ps", ["-ax", "-o", "pgid=,stat="], stderr_to_stdout: true) do
      {out, 0} ->
        {:ok,
         out
         |> String.split("\n", trim: true)
         |> Enum.flat_map(&parse_ps_line(&1, pgid))
         |> Enum.reject(&zombie?/1)}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp parse_ps_line(line, pgid) do
    case String.split(String.trim(line)) do
      [pg, stat | _] ->
        case Integer.parse(pg) do
          {^pgid, _} -> [stat]
          _ -> []
        end

      _ ->
        []
    end
  end

  defp zombie?(stat) when is_binary(stat), do: String.starts_with?(stat, "Z")
  defp zombie?(_), do: false

  defp kill_probe_alive?(pgid) do
    {out, status} = System.cmd("kill", ["-0", "-#{pgid}"], stderr_to_stdout: true)
    status == 0 or not esrch?(out)
  rescue
    _ -> true
  end

  defp esrch?(out) do
    down = String.downcase(out)
    String.contains?(down, "no such process") or String.contains?(down, "esrch")
  end
end
