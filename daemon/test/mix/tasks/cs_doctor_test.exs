defmodule Mix.Tasks.Cs.DoctorTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Consigliere.Home

  setup do
    home =
      Path.join(System.tmp_dir!(), "cs-home-doctor-test-#{System.unique_integer([:positive])}")

    System.put_env("CS_HOME", home)

    on_exit(fn ->
      System.delete_env("CS_HOME")
      File.rm_rf!(home)
    end)

    %{home: home}
  end

  test "reports not running when nothing has ever bound the socket" do
    output = capture_io(fn -> Mix.Tasks.Cs.Doctor.run([]) end)

    assert output =~ "probe socket: absent"
  end

  test "reports running when a live instance holds the lock", %{home: home} do
    {:ok, pid} = Consigliere.Home.Lock.start_link(home: home)

    output = capture_io(fn -> Mix.Tasks.Cs.Doctor.run([]) end)

    assert output =~ "probe socket: live"
    GenServer.stop(pid)
  end

  test "reports a stale socket after a hard kill", %{home: home} do
    Process.flag(:trap_exit, true)
    {:ok, pid} = Consigliere.Home.Lock.start_link(home: home)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    output = capture_io(fn -> Mix.Tasks.Cs.Doctor.run([]) end)

    assert output =~ "stale"
  end

  test "surfaces the last recorded startup failure", %{home: home} do
    Home.record_error!(home, "simulated disk full")

    output = capture_io(fn -> Mix.Tasks.Cs.Doctor.run([]) end)

    assert output =~ "simulated disk full"
  end
end
