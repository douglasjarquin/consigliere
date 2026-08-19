defmodule Consigliere.CLITest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Consigliere.Home

  setup do
    home =
      Path.join(System.tmp_dir!(), "cs-home-cli-test-#{System.unique_integer([:positive])}")

    System.put_env("CS_HOME", home)

    on_exit(fn ->
      System.delete_env("CS_HOME")
      File.rm_rf!(home)
    end)

    %{home: home}
  end

  test "doctor/0 reports not running with no failure when the home is untouched" do
    output = capture_io(fn -> Consigliere.CLI.doctor() end)

    assert output =~ "not running"
    refute output =~ "last startup failure"
  end

  test "doctor/0 reports a stale socket plus the recorded failure cause", %{home: home} do
    Process.flag(:trap_exit, true)
    {:ok, pid} = Consigliere.Home.Lock.start_link(home: home)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    Home.record_error!(home, "eaddrinuse")

    output = capture_io(fn -> Consigliere.CLI.doctor() end)

    assert output =~ "stale"
    assert output =~ "eaddrinuse"
  end
end
