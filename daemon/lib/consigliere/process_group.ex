defmodule Consigliere.ProcessGroup do
  @moduledoc """
  Adopt-and-kill: SIGTERM, bounded wait, SIGKILL, bounded verify.
  Matches docs/protocols/runner.md termination sequence. Never signals
  pgid 0/1 (POSIX broadcast).
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

  defp gone?(pgid) do
    {out, status} = System.cmd("kill", ["-0", "-#{pgid}"], stderr_to_stdout: true)
    status != 0 and String.contains?(out, "No such process")
  rescue
    _ -> false
  end
end
