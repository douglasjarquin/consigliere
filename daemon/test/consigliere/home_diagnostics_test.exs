defmodule Consigliere.HomeDiagnosticsTest do
  use ExUnit.Case, async: true

  alias Consigliere.Home

  setup do
    home =
      Path.join(
        System.tmp_dir!(),
        "cs-home-diagnostics-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(home) end)
    %{home: home}
  end

  test "socket_status/1 is :absent when nothing has ever bound the socket", %{home: home} do
    assert Home.socket_status(home) == :absent
  end

  test "socket_status/1 is :live while a listener holds the socket", %{home: home} do
    {:ok, pid} = Consigliere.Home.Lock.start_link(home: home)

    assert Home.socket_status(home) == :live

    GenServer.stop(pid)
  end

  test "socket_status/1 is :stale once the listener dies without cleaning up", %{home: home} do
    Process.flag(:trap_exit, true)
    {:ok, pid} = Consigliere.Home.Lock.start_link(home: home)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    assert Home.socket_status(home) == :stale
  end

  test "record_error!/2 then last_error/1 round-trips the failure reason", %{home: home} do
    assert Home.last_error(home) == nil

    Home.record_error!(home, "config invalid: missing thing")

    assert Home.last_error(home) == "config invalid: missing thing"
  end

  test "clear_error!/1 removes a previously recorded failure", %{home: home} do
    Home.record_error!(home, "config invalid: missing thing")
    assert Home.last_error(home) == "config invalid: missing thing"

    Home.clear_error!(home)

    assert Home.last_error(home) == nil
  end

  test "clear_error!/1 is a no-op when there was never a recorded failure", %{home: home} do
    assert Home.last_error(home) == nil

    Home.clear_error!(home)

    assert Home.last_error(home) == nil
  end

  test "forced_failure_reason/0 reads CS_FORCE_STARTUP_FAILURE" do
    refute Home.forced_failure_reason()

    System.put_env("CS_FORCE_STARTUP_FAILURE", "boom")
    on_exit(fn -> System.delete_env("CS_FORCE_STARTUP_FAILURE") end)

    assert Home.forced_failure_reason() == "boom"
  end
end
