alias Consigliere.RunnerLauncher

dir = Path.join("/tmp", "csc-tmux-driver")
File.rm_rf!(dir)
File.mkdir_p!(dir)

manifest_path = Path.join(dir, "manifest.json")
control_socket_path = Path.join(dir, "control.sock")
heartbeat_path = Path.join(dir, "heartbeat")

{:ok, session} =
  RunnerLauncher.launch(
    attempt_id: "tmux-attempt-1",
    mission_id: "tmux-mission-1",
    fencing_token: "tmux-fence-1",
    manifest_path: manifest_path,
    control_socket_path: control_socket_path,
    harness_command: [Path.expand("../priv/fake_harness.sh", __DIR__), heartbeat_path]
  )

daemon_os_pid = System.pid()

IO.puts("""

=== Spike C Criterion 2: daemon-independent runner (live tmux driver) ===
daemon (this BEAM) OS pid: #{daemon_os_pid}
cs-runner OS pid:          #{session.runner_os_pid}
harness OS pid:            #{session.harness_pid}
process group id:          #{session.pgid}
manifest path:             #{manifest_path}
control socket path:       #{control_socket_path}
heartbeat path:            #{heartbeat_path}

From ANOTHER terminal/tmux pane, kill this daemon outright:
  kill -9 #{daemon_os_pid}

Then, still from outside, verify cs-runner detected the death on its own,
terminated the harness, and left a truthful manifest -- with nobody left
alive to ask:
  ps -p #{session.harness_pid}                # expect: gone
  ps -p #{session.runner_os_pid}               # expect: gone (cs-runner exits after writing the final manifest)
  cat #{manifest_path}                         # expect: "state": "dead_verified", "termination_reason": "control_eof"

This process is now blocking and will do nothing further -- it exists only
to hold the daemon open until it is killed.
""")

Process.sleep(:infinity)
