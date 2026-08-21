defmodule Consigliere.ProcessGroupTest do
  use ExUnit.Case, async: false

  alias Consigliere.ProcessGroup
  alias Consigliere.ProcessHelpers

  test "an unreaped killed session leader counts as gone" do
    {port, pgid} = ProcessHelpers.spawn_session_leader()
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    assert ProcessGroup.alive?(pgid)

    assert ProcessGroup.terminate(pgid, term_timeout_ms: 2_000, kill_timeout_ms: 1_000) ==
             :dead_verified

    refute ProcessGroup.alive?(pgid)
  end

  test "a pgid with no members is gone" do
    refute ProcessGroup.alive?(2_000_001)
    assert ProcessGroup.gone?(2_000_001)
  end

  test "probe/1 reports absent via errno, not English kill text" do
    assert ProcessGroup.probe(2_000_001) == :absent
  end

  test "probe/1 reports alive for a live session leader" do
    {port, pgid} = ProcessHelpers.spawn_session_leader()
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    assert ProcessGroup.probe(pgid) == :alive
  end

  test "probe/1 refuses to inspect pgid 0 or 1" do
    assert ProcessGroup.probe(0) == :unsafe
    assert ProcessGroup.probe(1) == :unsafe
  end
end
