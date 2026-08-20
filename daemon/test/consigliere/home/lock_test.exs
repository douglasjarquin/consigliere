defmodule Consigliere.Home.LockTest do
  use ExUnit.Case, async: true

  alias Consigliere.Home
  alias Consigliere.Home.Lock

  setup do
    home = Path.join(System.tmp_dir!(), "cs-home-lock-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(home) end)
    %{home: home}
  end

  test "a second start for the same home reuses the live lock process", %{home: home} do
    assert {:ok, pid1} = Lock.start_link(home: home)
    assert {:ok, pid2} = Lock.start_link(home: home)
    assert pid1 == pid2
    GenServer.stop(pid1)
  end

  test "a leftover socket file is removed after the kernel lock is held", %{home: home} do
    socket = Home.boss_socket_path(home)
    File.mkdir_p!(home)
    File.write!(socket, "not-a-socket")

    assert {:ok, pid} = Lock.start_link(home: home)
    assert File.exists?(socket)
    assert Home.socket_status(home) == :live
    assert match?({:held, _}, Home.lock_status(home)) or File.exists?(Home.lock_path(home))
    GenServer.stop(pid)
  end

  test "an external fcntl holder blocks a second daemon lock", %{home: home} do
    Process.flag(:trap_exit, true)
    File.mkdir_p!(home)
    lock_path = Home.lock_path(home)
    probe = Lock.probe_binary()
    port = Port.open({:spawn_executable, probe}, [:binary, :exit_status, args: ["hold", lock_path]])
    assert_receive {^port, {:data, "held\n"}}, 2_000

    assert {:error, :already_running} = Lock.start_link(home: home)
    refute File.exists?(Home.boss_credential_path(home))
    refute File.exists?(Home.owner_path(home))

    Port.close(port)
  end

  test "a stale lock file without a holder does not block startup", %{home: home} do
    File.mkdir_p!(home)
    File.write!(Home.lock_path(home), "leftover")
    File.chmod!(Home.lock_path(home), 0o600)

    assert {:ok, pid} = Lock.start_link(home: home)
    assert File.exists?(Home.owner_path(home))
    GenServer.stop(pid)
  end

  test "kill of the lock process releases the kernel lock", %{home: home} do
    Process.flag(:trap_exit, true)
    assert {:ok, pid} = Lock.start_link(home: home)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    assert {:ok, pid2} = Lock.start_link(home: home)
    GenServer.stop(pid2)
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

  test "a second start for the same home does not unbind the live probe", %{home: home} do
    assert {:ok, winner} = Lock.start_link(home: home)
    socket = Home.boss_socket_path(home)
    assert File.exists?(socket)

    assert {:ok, ^winner} = Lock.start_link(home: home)
    assert File.exists?(socket)
    assert Home.socket_status(home) == :live

    GenServer.stop(winner)
  end

  test "a stripped PATH still takes CS_HOME", %{home: home} do
    previous = System.get_env("PATH")
    System.put_env("PATH", "/nonexistent")

    on_exit(fn ->
      if previous, do: System.put_env("PATH", previous), else: System.delete_env("PATH")
    end)

    assert {:ok, pid} = Lock.start_link(home: home)
    GenServer.stop(pid)
  end

  test "two different homes can be locked at once" do
    a = Path.join(System.tmp_dir!(), "cs-home-lock-a-#{System.unique_integer([:positive])}")
    b = Path.join(System.tmp_dir!(), "cs-home-lock-b-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.rm_rf(a)
      File.rm_rf(b)
    end)

    assert {:ok, pa} = Lock.start_link(home: a)
    assert {:ok, pb} = Lock.start_link(home: b)
    assert Home.socket_status(a) == :live
    assert Home.socket_status(b) == :live
    GenServer.stop(pa)
    GenServer.stop(pb)
  end
end
