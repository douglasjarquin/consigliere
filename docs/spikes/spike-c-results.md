# Spike C results: daemon-bound runner

Status: draft, all documented criteria pass with RED/GREEN test evidence plus a live tmux/OS-level channel scenario for the daemon-kill invariant; submitted to the `omo:reviewer` verification-gate loop, not yet closed. This document will be updated with the honest round-by-round outcome, per this project's established practice (see `docs/spikes/spike-b-results.md`), rather than rewritten to hide any rejection.

This spike proves that a real, external, daemon-independent OS process (`cs-runner`, written in Go) survives a `kill -9` of the entire Elixir daemon, detects that death on its own (via control-channel EOF, no daemon-side cooperation), terminates the harness process group it owns, verifies that termination at the OS level, and leaves a truthful manifest behind -- and that a reconciler function reading that manifest after the fact reaches the correct classification, per `docs/phase0-report.md` section 15's Spike C design and `docs/protocols/runner.md`.

## What was built

- `runner/cs-runner/` (Go): a standalone runner binary, independent of the Elixir daemon's own lifetime.
  - `manifest.go`: crash-safe manifest read/write (temp file + fsync + atomic rename + directory fsync), matching `docs/protocols/runner.md`'s schema.
  - `spawn.go`: spawns the harness as its own session/process-group leader (`Setsid: true`) and blocks until the child's own `setsid()` call is confirmed via `Getpgid` before returning -- closing a real startup race (see "Two real races found" below).
  - `termination.go`: the SIGTERM / bounded-wait / SIGKILL / bounded-verify sequence from `docs/protocols/runner.md`'s "Termination sequence" section, verifying death via `kill(-pgid, 0)`, never by trusting `Wait()` alone.
  - `control.go`: the runner-as-server NDJSON Unix-domain-socket control channel. `ReadLoop`'s EOF path is the entire daemon-independence mechanism: a `kill -9` of the daemon closes every file descriptor it held, including its end of this socket, which surfaces here as an ordinary read EOF with zero daemon-side cooperation required.
  - `main.go`: wires the full lifecycle -- write `starting` manifest, spawn harness, write `running` manifest, accept the daemon's control connection, race the harness's own exit against a control-channel-triggered termination (`cancel` message or EOF), run the termination sequence if triggered, write the final `dead_verified`/`dead_unverified` manifest, send `termination_complete`, exit.
- `daemon/lib/consigliere/runner_launcher.ex` (Elixir): the daemon-side half of the protocol for this spike -- `Port.open/2`-spawns `cs-runner`, connects to its control socket as a `:gen_tcp` `{:local, path}` client, and exposes `launch/1`, `cancel/1`, `recv/2`. Deliberately minimal and not a supervised OTP process: it exists to prove the protocol boundary, not to be the real production launcher (that belongs to Phase 1/2, once `RunnerProcess` from Spike B is rebuilt on top of `cs-runner` instead of a plain Port-spawned fake harness).
- `daemon/lib/consigliere/reconciler.ex` (Elixir): `Reconciler.classify/1` reads a manifest file from disk and classifies it per `docs/protocols/runner.md`'s "Restart and reconciliation contract": `dead_verified` -> `:lost`; `dead_unverified` -> `:quarantine_incident`; any non-terminal state (`starting`/`running`/`terminating`) -> a real OS-level process-group liveness check (`kill -0 -<pgid>`) decides between `:adopt_and_kill` (group still alive) and `:lost` (treated as `dead_verified` after the fact, per the protocol); anything unparseable or unrecognized -> `:quarantine_incident` with `:corrupt`, never a crash. This spike deliberately does not cross-reference a real Attempt row or touch SQLite -- there is no Mission/Attempt/Workspace schema in this spike's scope, only the classification function itself.
- `daemon/spike_scripts/spike_c_driver.exs`: the live tmux/OS-level demonstration script for the daemon-kill invariant, analogous to Spike B's `coordinator_independence_driver.exs`.

## Two real races found (not assumed, reproduced and fixed)

1. **`setsid()` startup TOCTOU**: `cmd.Start()` returns to the parent as soon as `fork()` completes; the child's own `setsid()` call happens asynchronously afterward. An immediate `kill(-pgid, 0)` check (or, worse, the real termination sequence) executed in that window can silently miss the child, because the process group it actually joins isn't confirmed yet. Found via a genuinely failing `termination_test.go` run, not assumed. Fixed by removing `Terminate`'s racy "already dead" fast path entirely, and by having `SpawnHarness` poll `Getpgid(pid) == pid` before returning a `HarnessHandle` to any caller -- the same fix applied at the real call site (`main.go`), not just in the test helper.
2. **Shell `trap` installation timing**: even after fixing race 1, a test harness that installs `trap '' TERM` to ignore SIGTERM (to exercise the SIGKILL escalation path) still failed intermittently, because the shell needs time to actually execute the `trap` builtin before a signal sent immediately afterward is honored against that new disposition -- sending it too early kills the shell via the *default* disposition instead, never reaching the SIGKILL path the test meant to exercise. Fixed with a real synchronization marker (the shell `touch`es a ready-file immediately after the `trap` statement; the test polls for that file) instead of an arbitrary `sleep`, which would have been nondeterministic.

## A real OS constraint found: socket path length

macOS's `sockaddr_un.sun_path` limit (~104 bytes) caused `bind: invalid argument` when a control-socket path was built under `t.TempDir()`'s long, deeply nested per-test directories. Fixed with short paths directly under `/tmp` (a `shortSocketDir(t)` helper in Go tests, `/tmp/csc-*` directories in Elixir tests and the driver script) -- and this is exactly why the real runner protocol's production path (`/var/run/csd/attempts/<attempt_id>/`) is deliberately short rather than nested under a long project-specific prefix.

## Results by criterion

Numbering follows `docs/phase0-report.md` section 15's Spike C list.

1-2. **Start a harness through the external runner; `kill -9` the entire daemon process.** Proven live via `daemon/spike_scripts/spike_c_driver.exs` run under `mix run` inside a tmux pane, killed from a separate shell with `kill -9 <daemon OS pid>`. Also covered automatically (without needing a literal whole-BEAM kill) by `daemon/test/consigliere/runner_launcher_test.exs`'s third test, which closes the daemon's end of the control-channel socket directly -- the identical mechanism `kill -9` triggers at the kernel level (fd closure), per `control.go`'s own documented invariant.
3. **Runner observes control-channel EOF, independent of daemon shutdown logic.** Confirmed both live (see below) and in the automated test: `termination_reason` in the final manifest and in the `termination_complete` message is `"control_eof"`, distinct from the explicit `"cancel"` path also covered by the same test file.
4. **Graceful-term/bounded-wait/hard-kill sequence, verified via process-table inspection.** `termination.go`'s `Terminate/3` implements exactly this sequence (`termination.go`'s tests, Criterion 1 from Spike C's own Go-side work); the live and automated Elixir-side scenarios both confirm the harness process is actually gone (`kill -0` returns nonzero) after the sequence completes, not merely that `Wait()` returned.
5-7. **Restart the daemon; reconciler classifies the dead Attempt as lost; workspace state left evaluable, not ambiguous.** This spike has no real daemon-restart/boot sequence, Mission/Attempt schema, or Workspace entity to restart or reconcile against -- that is explicitly out of scope here (see `docs/phase0-report.md`'s Spike A/B precedent of proving mechanisms in isolation before Phase 1 wires them into the real schema). What this spike proves instead is the classification function itself: `Consigliere.Reconciler.classify/1`, tested in `daemon/test/consigliere/reconciler_test.exs` against (a) a real manifest produced by an actual `cs-runner` run through the cancel path (`:lost`), (b) a real still-running `cs-runner` process checked via a genuine OS-level process-group scan (`:adopt_and_kill`), (c) a forced `dead_unverified` manifest (`:quarantine_incident`), and (d) a manifest claiming `running` against a process group that is actually dead, using the same real `kill -0 -<pgid>` mechanism the production reconciler would use, not the manifest's own self-report (`:lost`, per the protocol's "verify independently" rule).
8. **Exit criterion.** Live evidence below shows zero processes surviving the kill, confirmed from outside the killed daemon by direct `ps`/`kill -0` inspection, plus the manifest's own `dead_verified`/`control_eof` record -- both independently pointing at the same conclusion, neither trusting the daemon's own report (there is no daemon left to report anything).

## Live evidence: kill -9 the daemon, from outside

Captured in a tmux session (`spike-c-driver`), `mix run daemon/spike_scripts/spike_c_driver.exs`, driver PID 90615:

```
$ ps -p 90615 -o pid,ppid,pgid,comm   # daemon (BEAM), before the kill
  90615 90394 90615 .../erts-17.0.5/bin/beam.smp
$ ps -p 90698 -o pid,ppid,pgid,comm   # cs-runner, before the kill
  90698 90664 90698 .../runner/cs-runner/cs-runner
$ ps -p 90699 -o pid,ppid,pgid,comm   # harness (fake_harness.sh), before the kill
  90699 90698 90699 /bin/sh

$ kill -9 90615                      # from a separate shell, outside the daemon

$ ps -p 90615   # gone
$ ps -p 90698   # gone (cs-runner exited cleanly after writing the final manifest)
$ ps -p 90699   # gone (harness terminated by cs-runner's own termination sequence)

$ cat /tmp/csc-tmux-driver/manifest.json
{
  "schema_version": 1,
  "attempt_id": "tmux-attempt-1",
  "mission_id": "tmux-mission-1",
  "fencing_token": "tmux-fence-1",
  "runner_pid": 90698,
  "harness_pid": 90699,
  "pgid": 90699,
  "harness_executable_path": ".../daemon/priv/fake_harness.sh",
  "harness_executable_sha256": "0f0aa995121ea9aab877e521b32b7a53f4ef6cedca60e96dd91239219e39a111",
  "started_at": "2026-08-19T03:34:42.574037Z",
  "control_socket_path": "/tmp/csc-tmux-driver/control.sock",
  "state": "dead_verified",
  "last_state_change_at": "2026-08-19T03:35:26.941585Z",
  "exit_code": null,
  "termination_reason": "control_eof",
  "verified_dead_at": "2026-08-19T03:35:26.941585Z"
}
```

All of this happened within about a second of the `kill -9`: `cs-runner`'s control-channel EOF fires the instant the kernel closes the daemon's socket fd, and `fake_harness.sh` (a simple shell loop with default SIGTERM disposition) terminates immediately on the first signal in the sequence.

Both `cs-runner` (pid 90698) and `erl_child_setup` (pid 90664, the Erlang VM's own helper process for spawning OS children, an unrelated implementation detail of how the Port was created) exited around the same time as the daemon; this was verified to be `cs-runner`'s own clean exit after completing its termination sequence and writing the final manifest (confirmed by the manifest content above), not a cascading kill of the subtree -- `cs-runner`'s control-channel connection is a plain socket fd owned directly by the BEAM process, not routed through `erl_child_setup`, so its EOF is caused by the daemon's death itself, independent of whatever happens to that helper process.

## Automated regression

`daemon/test/consigliere/runner_launcher_test.exs` (3 tests) and `daemon/test/consigliere/reconciler_test.exs` (12 tests) both RED (undefined module/function, confirmed before any implementation existed) then GREEN. Full `daemon/` suite: 34 tests (1 doctest, 33 tests), all passing, no regression against Spikes A/B. Go suite (`gofmt -l`, `go vet ./...`, `go test ./...`): clean. Flakiness check: both new Elixir test files repeated 20+ times back-to-back (same BEAM VM) with zero failures; no leftover `/tmp/csc-*` directories or `cs-runner`/`fake_harness.sh` processes after any run.

## Known limitations carried forward (not silently accepted)

- No real daemon boot/restart sequence, Mission/Attempt schema, or Workspace entity exists in this spike; `Consigliere.Reconciler.classify/1` proves the classification logic in isolation, matching this project's Spike A/B precedent of proving mechanisms before Phase 1 wires them into the real schema. Phase 1/2 must wire this into an actual `Csd.Reconciler` boot-time scan over `runners/<attempt_id>/manifest.json` files, cross-referenced against real Attempt rows, per `docs/protocols/runner.md`'s full restart contract (steps 2, 3, and 6 of that contract -- Attempt-row cross-reference, checkpoint-vs-lost distinction, and manifest archival -- are explicitly not built here).
- `daemon/lib/consigliere/runner_launcher.ex` is a spike-scoped helper, not a supervised OTP process. Phase 1/2's real launcher must be a proper supervised child (mirroring Spike B's `RunnerProcess`) that owns the `Port`/socket for the life of a real Attempt, not a bare struct returned from a function call.
- The 5-second graceful-wait / 2-second verify timeout budget from `docs/protocols/runner.md` was exercised only against a harness with default (near-instant) SIGTERM disposition; the "stubborn process that ignores SIGKILL" edge case is covered at the Go unit level (`termination_test.go`, inherited from Spike C's own Criterion 1 work) but was not re-exercised end-to-end through the Elixir launcher in this spike.

## Exit criteria

All eight numbered items from `docs/phase0-report.md` section 15's Spike C list are addressed, with the scope narrowing on items 5-7 documented above rather than silently assumed. Submitted to the `omo:reviewer` verification-gate loop; this section will be updated with the actual outcome once that loop reaches unconditional approval or surfaces findings to fix.
