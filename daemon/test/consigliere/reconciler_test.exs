defmodule Consigliere.ReconcilerTest do
  use ExUnit.Case, async: false

  alias Consigliere.RunnerLauncher
  alias Consigliere.Reconciler

  @fake_harness Path.expand("../../priv/fake_harness.sh", __DIR__)

  setup do
    {_, 0} =
      System.cmd("go", ["build", "-o", "cs-runner", "."],
        cd: RunnerLauncher.cs_runner_source_dir()
      )

    unique = System.unique_integer([:positive, :monotonic])
    dir = Path.join("/tmp", "csc-reconciler-test-#{unique}")
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

  describe "classify_manifest/2 (pure classification)" do
    test "dead_verified is classified as lost" do
      manifest = %{"state" => "dead_verified"}
      assert Reconciler.classify_manifest(manifest, fn -> true end) == {:lost, manifest}
    end

    test "dead_unverified is classified as quarantine_incident" do
      manifest = %{"state" => "dead_unverified"}

      assert Reconciler.classify_manifest(manifest, fn -> true end) ==
               {:quarantine_incident, manifest}
    end

    test "running with a live process group is classified as adopt_and_kill" do
      manifest = %{"state" => "running", "pgid" => 999}

      assert Reconciler.classify_manifest(manifest, fn -> true end) ==
               {:adopt_and_kill, manifest}
    end

    test "running with no surviving process group member is classified as lost, per the runner protocol's after-the-fact dead_verified rule" do
      manifest = %{"state" => "running", "pgid" => 999}
      assert Reconciler.classify_manifest(manifest, fn -> false end) == {:lost, manifest}
    end

    test "starting is treated the same as running (non-terminal, needs a liveness check)" do
      manifest = %{"state" => "starting", "pgid" => 999}
      assert Reconciler.classify_manifest(manifest, fn -> false end) == {:lost, manifest}
    end

    test "terminating is treated the same as running (non-terminal, needs a liveness check)" do
      manifest = %{"state" => "terminating", "pgid" => 999}
      assert Reconciler.classify_manifest(manifest, fn -> true end) == {:adopt_and_kill, manifest}
    end

    test "a non-terminal state with no pgid at all is quarantined rather than assumed lost" do
      manifest = %{"state" => "running"}
      assert Reconciler.classify_manifest(manifest, fn -> false end) == {:quarantine_incident, manifest}
    end

    for degenerate_pgid <- [0, 1, -5] do
      test "a non-terminal state with pgid #{degenerate_pgid} is quarantined rather than signaled, since kill(-#{degenerate_pgid}, ...) is a POSIX broadcast, not a specific group" do
        manifest = %{"state" => "running", "pgid" => unquote(degenerate_pgid)}
        assert Reconciler.classify_manifest(manifest, fn -> true end) == {:quarantine_incident, manifest}
        assert Reconciler.classify_manifest(manifest, fn -> false end) == {:quarantine_incident, manifest}
      end
    end
  end

  describe "kill_result_alive?/1 (distinguishes ESRCH from EPERM in kill's output)" do
    test "a successful kill (exit 0) means alive" do
      assert Reconciler.kill_result_alive?({"", 0}) == true
    end

    test "\"No such process\" (ESRCH-equivalent) means conclusively gone" do
      assert Reconciler.kill_result_alive?({"kill: -370: No such process\n", 1}) == false
    end

    test "\"Operation not permitted\" (EPERM) means unverifiable, never treated as gone" do
      assert Reconciler.kill_result_alive?({"kill: -370: Operation not permitted\n", 1}) == true
    end

    test "any other unrecognized failure output also means unverifiable, never treated as gone" do
      assert Reconciler.kill_result_alive?({"kill: something else entirely\n", 1}) == true
    end
  end

  describe "classify/1 forward progress under a broken environment" do
    test "a missing kill executable does not crash classify/1, and is treated as unverifiable rather than lost" do
      original_path = System.get_env("PATH")
      on_exit(fn -> System.put_env("PATH", original_path) end)

      empty_path_dir = Path.join(System.tmp_dir!(), "empty-path-#{System.unique_integer([:positive])}")
      File.mkdir_p!(empty_path_dir)
      on_exit(fn -> File.rm_rf(empty_path_dir) end)
      System.put_env("PATH", empty_path_dir)

      manifest_path =
        Path.join(System.tmp_dir!(), "enoent-manifest-#{System.unique_integer([:positive])}.json")

      on_exit(fn -> File.rm(manifest_path) end)
      File.write!(manifest_path, JSON.encode!(%{"state" => "running", "pgid" => 999}))

      assert {:adopt_and_kill, _manifest} = Reconciler.classify(manifest_path)
    end
  end

  describe "classify/1 (reads a manifest file from disk)" do
    test "a missing manifest file is quarantined as a corrupt incident", %{
      manifest_path: manifest_path
    } do
      assert Reconciler.classify(manifest_path) == {:quarantine_incident, :corrupt}
    end

    test "invalid JSON is quarantined as a corrupt incident, and does not raise", %{
      manifest_path: manifest_path
    } do
      File.write!(manifest_path, "{not valid json")
      assert Reconciler.classify(manifest_path) == {:quarantine_incident, :corrupt}
    end

    test "a forced dead_unverified manifest is quarantined as an incident", %{
      manifest_path: manifest_path
    } do
      manifest = %{
        "schema_version" => 1,
        "attempt_id" => "forced-unverified",
        "state" => "dead_unverified",
        "pgid" => 424_242
      }

      File.write!(manifest_path, JSON.encode!(manifest))

      assert Reconciler.classify(manifest_path) == {:quarantine_incident, manifest}
    end

    test "a real dead_verified manifest produced by cs-runner (Criterion 2's cancel path) is classified as lost",
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

      :ok = RunnerLauncher.cancel(session)
      assert {:ok, %{"type" => "termination_complete"}} =
               RunnerLauncher.recv_until(session, "termination_complete", 5_000)
      assert_receive {_port, {:exit_status, 0}}, 2_000

      assert {:lost, %{"state" => "dead_verified"}} = Reconciler.classify(manifest_path)
    end

    test "a real cs-runner still running is classified as adopt_and_kill via a real OS-level process-group check",
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

      assert {:adopt_and_kill, %{"state" => "running"}} = Reconciler.classify(manifest_path)

      :ok = RunnerLauncher.cancel(session)
      assert {:ok, _} = RunnerLauncher.recv_until(session, "termination_complete", 5_000)
      assert_receive {_port, {:exit_status, 0}}, 2_000
    end

    test "a manifest claiming running for a process group that is actually dead is classified as lost, via a real OS-level check (not the manifest's self-report)",
         %{manifest_path: manifest_path} do
      dead_pgid = find_definitely_dead_pid()

      manifest = %{
        "schema_version" => 1,
        "attempt_id" => "stale-running",
        "state" => "running",
        "pgid" => dead_pgid
      }

      File.write!(manifest_path, JSON.encode!(manifest))

      assert Reconciler.classify(manifest_path) == {:lost, manifest}
    end
  end

  defp find_definitely_dead_pid do
    {out, 0} = System.cmd("sh", ["-c", "true & echo $!"])
    pid = out |> String.trim() |> String.to_integer()
    wait_until_gone(pid, 50)
    pid
  end

  defp wait_until_gone(pid, attempts) do
    case System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true) do
      {_, 0} when attempts > 0 ->
        Process.sleep(20)
        wait_until_gone(pid, attempts - 1)

      {_, 0} ->
        flunk("pid #{pid} never died; cannot use it as a definitely-dead fixture")

      _ ->
        :ok
    end
  end
end
