alias Consigliere.RunnerLauncher

dir = Path.join("/tmp", "csc-escape-driver")
File.rm_rf!(dir)
File.mkdir_p!(dir)

manifest_path = Path.join(dir, "manifest.json")
control_socket_path = Path.join(dir, "control.sock")
heartbeat_path = Path.join(dir, "heartbeat")
grandchild_pid_path = Path.join(dir, "grandchild.pid")

test_binary = Path.expand("../../runner/cs-runner/cs-runner.test", __DIR__)

unless File.exists?(test_binary) do
  raise "test binary not found at #{test_binary} -- build it first: cd runner/cs-runner && go test -c -o cs-runner.test ."
end

{:ok, session} =
  RunnerLauncher.launch(
    attempt_id: "tmux-escape-attempt-1",
    mission_id: "tmux-escape-mission-1",
    fencing_token: "tmux-escape-fence-1",
    manifest_path: manifest_path,
    control_socket_path: control_socket_path,
    harness_command: [
      Path.expand("../priv/fake_harness_with_daemonizing_grandchild.sh", __DIR__),
      heartbeat_path,
      test_binary,
      "daemonize",
      grandchild_pid_path
    ]
  )

daemon_os_pid = System.pid()

wait_for_file = fn wait_for_file, path, deadline ->
  cond do
    File.exists?(path) ->
      :ok

    System.monotonic_time(:millisecond) > deadline ->
      raise "grandchild pid file never appeared: #{path}"

    true ->
      Process.sleep(20)
      wait_for_file.(wait_for_file, path, deadline)
  end
end

wait_for_file.(wait_for_file, grandchild_pid_path, System.monotonic_time(:millisecond) + 5_000)

grandchild_pid = grandchild_pid_path |> File.read!() |> String.trim()

IO.puts("""

=== Daemonize-escape fix: live tmux driver ===
daemon (this BEAM) OS pid:  #{daemon_os_pid}
cs-runner OS pid:           #{session.runner_os_pid}
harness OS pid:             #{session.harness_pid}
harness process group id:  #{session.pgid}
escaped grandchild OS pid:  #{grandchild_pid}  (called setsid() itself -- NOT in the harness's own process group)
manifest path:              #{manifest_path}

Confirm the escape for yourself before killing anything:
  ps -o pid,pgid,comm -p #{session.harness_pid}
  ps -o pid,pgid,comm -p #{grandchild_pid}
  (the two PGID columns will differ -- the grandchild is in its own group)

From ANOTHER terminal/tmux pane, kill this daemon outright:
  kill -9 #{daemon_os_pid}

Then, still from outside, verify cs-runner detected the death on its own,
terminated BOTH the harness group AND the escaped grandchild -- with
nobody left alive to ask:
  ps -p #{session.harness_pid}    # expect: gone
  ps -p #{grandchild_pid}         # expect: gone -- this is the fix under test
  ps -p #{session.runner_os_pid}  # expect: gone (cs-runner exits after writing the final manifest)
  cat #{manifest_path}            # expect: "state": "dead_verified", "termination_reason": "control_eof"

This process is now blocking and will do nothing further -- it exists only
to hold the daemon open until it is killed.
""")

Process.sleep(:infinity)
