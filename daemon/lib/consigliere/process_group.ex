defmodule Consigliere.ProcessGroup do
  @moduledoc """
  Adopt-and-kill: SIGTERM, bounded wait, SIGKILL, bounded verify.
  Matches docs/protocols/runner.md termination sequence. Never signals
  pgid 0/1 (POSIX broadcast).

  Linux keeps unreaped children as zombies, and `kill -0` succeeds on a
  zombie. Zombies cannot run, so they count as gone.
  """

  @kill_paths ["/bin/kill", "/usr/bin/kill"]
  @ps_paths ["/bin/ps", "/usr/bin/ps"]
  @observer_timeout_ms 2_000

  alias Consigliere.Runtime.Command

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

  def probe(pgid) when is_integer(pgid) and pgid > 1 do
    Consigliere.ProcessGroup.NIF.probe(pgid)
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  def probe(_), do: :unsafe

  def liveness(pgid) when is_integer(pgid) and pgid > 1 do
    case runnable_members(pgid) do
      {:ok, []} ->
        :absent

      {:ok, _members} ->
        :verified

      :error ->
        case probe(pgid) do
          :alive -> :verified
          :absent -> :absent
          :forbidden -> :permission_unknown
          :unknown -> :observation_failed
          _ -> :observation_failed
        end
    end
  end

  def liveness(_), do: :identity_mismatch

  def member?(pid, pgid) when is_integer(pid) and pid > 1 and is_integer(pgid) and pgid > 1 do
    membership(pid, pgid) == :member
  end

  def member?(_pid, _pgid), do: false

  def membership(pid, pgid)
      when is_integer(pid) and pid > 1 and is_integer(pgid) and pgid > 1 do
    case :os.type() do
      {:unix, :linux} -> linux_membership(pid, pgid)
      _ -> ps_membership(pid, pgid)
    end
  rescue
    _ -> :unknown
  end

  def membership(_pid, _pgid), do: :unknown

  def alive?(pgid) when is_integer(pgid) and pgid > 1 do
    liveness(pgid) != :absent
  end

  def alive?(_), do: false

  def gone?(pgid), do: not alive?(pgid)

  defp signal(pgid, sig) do
    case tool_path(@kill_paths) do
      nil ->
        {"", 1}

      kill ->
        case Command.run(kill, [sig, "--", "-#{pgid}"], timeout_ms: @observer_timeout_ms) do
          {:ok, output, status} -> {output, status}
          {:error, _reason, output} -> {output, 1}
        end
    end
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
    case :os.type() do
      {:unix, :linux} -> linux_runnable(pgid)
      _ -> ps_runnable(pgid)
    end
  end

  defp linux_runnable(pgid) do
    case File.ls("/proc") do
      {:ok, entries} ->
        entries
        |> Enum.filter(&numeric_entry?/1)
        |> Enum.reduce_while({:ok, []}, fn entry, {:ok, stats} ->
          case read_proc_stat(Path.join(["/proc", entry, "stat"]), pgid) do
            {:ok, values} -> {:cont, {:ok, stats ++ values}}
            :absent -> {:cont, {:ok, stats}}
            :error -> {:halt, :error}
          end
        end)
        |> case do
          {:ok, stats} -> {:ok, Enum.reject(stats, &zombie?/1)}
          :error -> :error
        end

      {:error, _reason} ->
        :error
    end
  rescue
    _ -> :error
  end

  defp read_proc_stat(path, pgid) do
    case File.read(path) do
      {:ok, contents} -> {:ok, parse_proc_stat(contents, pgid)}
      {:error, :enoent} -> :absent
      {:error, _reason} -> :error
    end
  end

  defp parse_proc_stat(contents, pgid) do
    case Regex.run(~r/\) ([A-Za-z]) \d+ (\d+)/, contents) do
      [_, state, pgrp] ->
        case Integer.parse(pgrp) do
          {^pgid, _} -> [state]
          _ -> []
        end

      _ ->
        []
    end
  end

  defp linux_membership(pid, pgid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, contents} -> proc_stat_membership(contents, pgid)
      {:error, :enoent} -> :absent
      {:error, _reason} -> :unknown
    end
  end

  defp proc_stat_membership(contents, pgid) do
    case Regex.run(~r/\) [A-Za-z] \d+ (\d+)/, contents, capture: :all_but_first) do
      [pgrp] -> if Integer.parse(pgrp) == {pgid, ""}, do: :member, else: :not_member
      _ -> :unknown
    end
  end

  defp ps_membership(pid, pgid) do
    case tool_path(@ps_paths) do
      nil ->
        :unknown

      ps ->
        case Command.run(ps, ["-o", "pgid=", "-p", Integer.to_string(pid)],
               timeout_ms: @observer_timeout_ms
             ) do
          {:ok, output, 0} ->
            case Integer.parse(String.trim(output)) do
              {^pgid, ""} -> :member
              {_other, ""} -> :not_member
              _ -> :unknown
            end

          {:ok, output, _status} ->
            if String.contains?(String.downcase(output), "no such process"),
              do: :absent,
              else: :unknown

          {:error, _reason, _output} ->
            :unknown
        end
    end
  rescue
    _ -> :unknown
  end

  defp ps_runnable(pgid) do
    case tool_path(@ps_paths) do
      nil ->
        :error

      ps ->
        case Command.run(ps, ["-axo", "pgid=,stat="], timeout_ms: @observer_timeout_ms) do
          {:ok, out, 0} ->
            {:ok,
             out
             |> String.split("\n", trim: true)
             |> Enum.flat_map(&parse_ps_line(&1, pgid))
             |> Enum.reject(&zombie?/1)}

          _ ->
            :error
        end
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

  defp tool_path(paths), do: Enum.find(paths, &File.regular?/1)

  defp numeric_entry?(entry), do: Regex.match?(~r/\A[0-9]+\z/, entry)
end
