defmodule Consigliere.Home.LockTest do
  use ExUnit.Case, async: true

  alias Consigliere.Home
  alias Consigliere.Home.Lock

  setup do
    home = Path.join(System.tmp_dir!(), "cs-home-lock-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(home) end)
    %{home: home}
  end

  test "a second start is refused while the first instance is live", %{home: home} do
    Process.flag(:trap_exit, true)
    assert {:ok, pid1} = Lock.start_link(home: home)

    assert {:error, :already_running} = Lock.start_link(home: home)

    GenServer.stop(pid1)
  end

  test "a stale socket left by a dead instance is cleaned up and rebound", %{home: home} do
    Process.flag(:trap_exit, true)
    assert {:ok, pid1} = Lock.start_link(home: home)
    socket_path = Home.boss_socket_path(home)
    assert File.exists?(socket_path)

    ref = Process.monitor(pid1)
    Process.exit(pid1, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid1, :killed}

    # nothing cleans the file up on a hard kill -- it's genuinely stale on disk
    assert File.exists?(socket_path)

    assert {:ok, pid2} = Lock.start_link(home: home)
    GenServer.stop(pid2)
  end

  test "the socket file is removed when the lock holder stops cleanly", %{home: home} do
    assert {:ok, pid1} = Lock.start_link(home: home)
    socket_path = Home.boss_socket_path(home)
    assert File.exists?(socket_path)

    GenServer.stop(pid1)

    refute File.exists?(socket_path)
  end

  test "repeated status probes never make a live lock look stale", %{home: home} do
    assert {:ok, pid} = Lock.start_link(home: home)

    for _ <- 1..20 do
      assert Home.socket_status(home) == :live
    end

    GenServer.stop(pid)
  end
end
