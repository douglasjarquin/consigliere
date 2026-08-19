defmodule Consigliere.RunnerLauncherTest do
  use ExUnit.Case, async: false

  alias Consigliere.RunnerLauncher

  @fake_harness Path.expand("../../priv/fake_harness.sh", __DIR__)

  setup do
    {_, 0} =
      System.cmd("go", ["build", "-o", "cs-runner", "."],
        cd: RunnerLauncher.cs_runner_source_dir()
      )

    unique = System.unique_integer([:positive, :monotonic])
    dir = Path.join("/tmp", "csc-test-#{unique}")
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf(dir) end)

    %{
      dir: dir,
      manifest_path: Path.join(dir, "manifest.json"),
      control_socket_path: Path.join(dir, "control.sock"),
      heartbeat_path: Path.join(dir, "heartbeat"),
      attempt_id: "attempt-#{unique}",
      mission_id: "mission-#{unique}",
      fencing_token: "fence-#{unique}"
    }
  end

  test "cancel over the control channel produces a verified, dead_verified manifest", %{
    manifest_path: manifest_path,
    control_socket_path: control_socket_path,
    heartbeat_path: heartbeat_path,
    attempt_id: attempt_id,
    mission_id: mission_id,
    fencing_token: fencing_token
  } do
    {:ok, session} =
      RunnerLauncher.launch(
        attempt_id: attempt_id,
        mission_id: mission_id,
        fencing_token: fencing_token,
        manifest_path: manifest_path,
        control_socket_path: control_socket_path,
        harness_command: [@fake_harness, heartbeat_path]
      )

    assert session.harness_pid > 0
    assert {_output, 0} = System.cmd("kill", ["-0", to_string(session.harness_pid)])

    :ok = RunnerLauncher.cancel(session)

    assert {:ok, %{"type" => "termination_complete"} = msg} = RunnerLauncher.recv(session, 5_000)
    assert msg["verified_dead"] == true
    assert msg["termination_reason"] == "cancel"

    assert_receive {port, {:exit_status, 0}}, 2_000
    assert port == session.port

    assert %{"state" => "dead_verified", "termination_reason" => "cancel"} =
             read_manifest(manifest_path)

    refute_harness_alive(session.harness_pid)
  end

  test "harness exiting on its own produces a verified, dead_verified manifest with its exit code",
       %{
         manifest_path: manifest_path,
         control_socket_path: control_socket_path,
         heartbeat_path: heartbeat_path,
         attempt_id: attempt_id,
         mission_id: mission_id,
         fencing_token: fencing_token
       } do
    {:ok, session} =
      RunnerLauncher.launch(
        attempt_id: attempt_id,
        mission_id: mission_id,
        fencing_token: fencing_token,
        manifest_path: manifest_path,
        control_socket_path: control_socket_path,
        harness_command: [@fake_harness, heartbeat_path, "3"]
      )

    assert {:ok, %{"type" => "harness_exited"} = msg} = RunnerLauncher.recv(session, 5_000)
    assert msg["exit_code"] == 0

    assert_receive {port, {:exit_status, 0}}, 2_000
    assert port == session.port

    assert %{"state" => "dead_verified", "exit_code" => 0} = read_manifest(manifest_path)
  end

  test "closing the control connection without cancelling (simulating daemon death) still yields a verified termination",
       %{
         manifest_path: manifest_path,
         control_socket_path: control_socket_path,
         heartbeat_path: heartbeat_path,
         attempt_id: attempt_id,
         mission_id: mission_id,
         fencing_token: fencing_token
       } do
    {:ok, session} =
      RunnerLauncher.launch(
        attempt_id: attempt_id,
        mission_id: mission_id,
        fencing_token: fencing_token,
        manifest_path: manifest_path,
        control_socket_path: control_socket_path,
        harness_command: [@fake_harness, heartbeat_path]
      )

    harness_pid = session.harness_pid

    :gen_tcp.close(session.socket)

    assert_receive {port, {:exit_status, 0}}, 3_000
    assert port == session.port

    assert %{"state" => "dead_verified", "termination_reason" => "control_eof"} =
             read_manifest(manifest_path)

    refute_harness_alive(harness_pid)
  end

  defp read_manifest(path) do
    path |> File.read!() |> JSON.decode!()
  end

  defp refute_harness_alive(pid, attempts \\ 20) do
    case System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true) do
      {_, 0} when attempts > 0 ->
        Process.sleep(50)
        refute_harness_alive(pid, attempts - 1)

      {_, 0} ->
        flunk("harness pid #{pid} is still alive")

      _ ->
        :ok
    end
  end
end
