# Spike E results: packaging

Status: **done, within the descoped scope.** Scenarios 2 and 3 (single-instance lock, stale-socket recovery), the diagnosability half of scenarios 4 and 5, and the release binary plus its process-group-survival proof are all done, live-verified, and adversarially reviewed (an independent fable-model audit found four real gaps in the first draft of this work, all now fixed -- see "Adversarial review" below). The LaunchAgent half of scenarios 1 and 4 is deliberately descoped (see `docs/phase0-report.md` section 11's "Decision" note) since `herdr`, not `launchd`, holds the daemon's lifecycle in this project's actual deployment model; what replaces it (a real release binary, proven to survive its launching process group dying, plus the doctor/start protocol below) is done instead.

This spike proves that exactly one daemon instance can ever own a given home directory, that a stale lock left behind by an unclean shutdown self-heals on the next start, and that a startup failure is diagnosable through a CLI command rather than raw-log inspection, per `docs/phase0-report.md` section 11's Spike E design.

## What was built

- `daemon/lib/consigliere/home.ex`: `Consigliere.Home` resolves `CS_HOME` (falling back to `~/.consigliere`) and computes the paths every other piece needs from it -- `boss_socket_path/1`, `last_error_path/1` -- plus the diagnostic primitives `socket_status/1` (`:live`/`:stale`/`:absent`, via the same connect-probe the lock itself uses), `record_error!/2`, `clear_error!/1`, `last_error/1`, and `forced_failure_reason/0` (reads `CS_FORCE_STARTUP_FAILURE`, a test-only hook for deterministically failing a boot).
- `daemon/lib/consigliere/home/lock.ex`: `Consigliere.Home.Lock`, a `GenServer` wired as the first child of `Consigliere.Application`'s supervision tree. On boot it connects to `<home>/boss.sock` as a client first: something answers means live, and boot fails with `{:error, :already_running}`; nothing answers (stale file or absent) means it deletes any stale file and binds fresh. A linked acceptor process drains the listen socket's accept queue (see "A real bug this live QA found" below) so repeated status probes can never make a live lock look stale.
- `daemon/lib/consigliere/application.ex`: `Consigliere.Application.start/2` checks `forced_failure_reason/0` first (test-only fast-fail path, recording the reason before ever touching the supervisor). The real `start_supervisor/0` path routes its `Supervisor.start_link/2` result through `record_boot_result/2`, which clears any previously recorded failure on a successful boot, records any *real* failure (not just the forced-hook one), and explicitly does not record a benign `:already_running` refusal, since that's expected contention already surfaced independently through `socket_status/1` rather than an actual problem.
- `daemon/lib/mix/tasks/cs.doctor.ex`: `mix cs.doctor` prints exactly one of running/stale/not-running (via `socket_status/1`) plus the last recorded startup failure, if any (via `last_error/1`) -- one actionable line instead of raw logs.
- `daemon/config/test.exs`: pins `CS_HOME` to a tmp path for the whole test run, so `mix test` never touches the boss's real `~/.consigliere` (this was a live consequence found during the first implementation pass: an early full-suite run bound a real `boss.sock` under the boss's actual home directory before this fix).
- `daemon/lib/consigliere/cli.ex`: `Consigliere.CLI.doctor/0` -- the same diagnostic logic, extracted to plain `IO.puts` (not `Mix.shell()`, which isn't loaded in a release) so it's callable identically from `mix cs.doctor` (now a two-line wrapper) and from a real release via `bin/consigliere_daemon eval "Consigliere.CLI.doctor()"`.
- `daemon/mix.exs` / `daemon/rel/env.sh.eex`: a `releases:` block so `mix release` produces a real `bin/consigliere_daemon` with `start`/`daemon`/`eval` for free, plus `RELEASE_DISTRIBUTION=none` -- a release's default fixed `sname` node would collide on `epmd` before `Home.Lock` ever runs, misattributing the failure and risking a false collision across genuinely different `CS_HOME`s; disabling distribution sidesteps this entirely, and this project already treats OS signals, not distributed-Erlang `stop`/`remote`, as the primary shutdown path.

## The doctor/start protocol (agent instructions, not application code)

Per the boss's explicit direction (matching how `cs` today and firstmate's original design keep this decision in the harness/agent-instructions layer, not compiled into the daemon), whatever holds the daemon's lifecycle -- `herdr`, or a human at a terminal -- should follow this exact sequence, never a bare "just run start":

1. Run `mix cs.doctor` in dev, or `bin/consigliere_daemon eval "Consigliere.CLI.doctor()"` against a built release. If it reports **running**, do nothing further -- the daemon is already up.
2. If it reports **stale** or **not running**, run the start command (`bin/consigliere_daemon daemon` for a release). A stale socket self-heals automatically (see scenario 3 below); no separate cleanup step is needed.
3. **Do not trust the start command's exit code alone to mean success.** Confirmed live (see "Live evidence" below): a release's `daemon` command detaches and returns exit 0 before the application has actually finished booting -- exit 0 on a genuine successful boot and exit 0 on a refused `:already_running` attempt are indistinguishable from the exit code alone. A foreground `start` is not much better: an `:already_running` refusal and a genuinely broken boot both exit 1. Poll doctor afterward instead: **running** means it worked (whether this attempt won the race or a concurrent one did -- either is success); if it still reports **not running**, read the `last startup failure` line doctor now prints -- that is the specific, actionable cause, not a generic error.

This is why `record_boot_result/2` (above) deliberately excludes `:already_running` from `last_error.log`: if it were recorded, a harness racing two sessions to start the same home would see a "startup failure" logged for what was actually a completely healthy, expected outcome, undermining step 3's exact distinction.

## Results by criterion

Numbering follows `docs/phase0-report.md` section 11's Spike E list.

1. **LaunchAgent install and start-on-login.** Descoped -- see `docs/phase0-report.md` section 11's "Decision" note. `herdr` holds the daemon's lifecycle in this project's actual deployment model, not `launchd`.
2. **A second instance is refused while the first is live.** Proven by `daemon/test/consigliere/home/lock_test.exs` and live via tmux: booted instance A against a fresh `CS_HOME`, attempted instance B against the same home, and B's boot failed with `{:error, :already_running}` (Mix reported `shutdown: failed to start child: Consigliere.Home.Lock ** (EXIT) :already_running`).
3. **A stale socket self-heals on next start.** Proven live: hard-killed instance A (`kill -9` on the beam.smp OS pid, not a graceful stop) with `ls` confirming the socket file survived the kill; booted instance C against the same home, which bound cleanly with no manual cleanup; a fourth instance D against C was then refused again, confirming C genuinely holds a fresh, live lock rather than having silently failed to bind.
4. **Crash-loop bounding (LaunchAgent) and diagnosable failure cause (`cs doctor`).** The LaunchAgent restart-bounding half is descoped along with scenario 1. The diagnosability half is done and live-verified twice: once via the `CS_FORCE_STARTUP_FAILURE` test hook (forced a real boot crash, then `mix cs.doctor` reported `daemon not running` plus `last startup failure: disk full simulated`), and once via a genuine non-hook failure (a real directory placed at the socket path forced an actual `{:bind_failed, :eaddrinuse}` bind failure; `mix cs.doctor` reported the exact cause; fixing the underlying problem and rebooting cleanly then cleared the recorded failure, confirmed by `last_error.log` being absent afterward).
5. **Exit criterion.** The single-instance-ownership half is proven above (scenarios 2-3, plus the accept-queue fix below, which was necessary for that guarantee to hold under repeated real-world status checks, not just a single check) and confirmed again against the real release binary (two different `CS_HOME`s ran concurrently with no false collision; a second `daemon`-mode attempt against an already-live home left exactly one live `beam.smp` process for that home, confirmed by both `ps` and doctor, despite exiting 0). The CLI-diagnosability half is proven above (scenario 4) and confirmed working with no Mix present, via a real release's `eval` command. See "Live evidence: process-group survival" below for the replacement proof of the daemon surviving independent of whatever launched it.

## A real bug this live QA found (not assumed, reproduced and fixed)

The lock's listen socket was bound but nothing ever called `accept/1` on it. A status probe (the lock's own `already_running` check, or `cs doctor`'s independent check) connects and immediately disconnects without ever being accepted, so the connection sits in the kernel's backlog until something drains it. With the original `backlog: 1` and no acceptor, this queue filled after a single probe: doing the exact live sequence above (boot A, attempt B, then run `mix cs.doctor` from a third shell) made doctor report **stale** even though A was genuinely still live and healthy. Left unfixed, the next boot attempt in that state would have deleted a live daemon's socket file and ended up with two live daemons silently sharing one home -- exactly the failure this spike exists to prevent.

Fixed with a linked acceptor loop (`accept_loop/1` in `lock.ex`) that accepts and immediately closes each connection, plus a larger backlog (128) for headroom. A regression test (`test/consigliere/home/lock_test.exs`, "repeated status probes never make a live lock look stale") reproduces the exact failure with 20 sequential probes against a live lock, confirmed genuinely RED against the pre-fix code. Re-ran the exact live sequence that found the bug afterward: three consecutive `mix cs.doctor` calls following a refused second-instance attempt all correctly reported "daemon running."

## Live evidence: process-group survival

This is the replacement proof for what a LaunchAgent's restart-on-crash guarantee was meant to cover, scoped to what a `herdr`-launched process actually needs: surviving the death of whatever launched it, since this project has its own recorded incident (ADR-003's dead-owner incident, 213 revivals) of a daemon process launched via `nohup ... & disown` from inside a bounded agent tool call dying along with that call's process group.

Launched the release's `daemon` command inside its own fresh session (`perl -e 'use POSIX qw(setsid); setsid(); exec @ARGV' -- bash -c '...'`, since macOS ships no `setsid` binary), capturing the launcher's pgid from the inner shell's own `$$`:

```
$ perl -e "use POSIX qw(setsid); setsid(); exec @ARGV" -- bash -c "echo LAUNCHER_PGID=\$\$; ...; consigliere_daemon daemon; echo DAEMON_CMD_EXIT=\$?; sleep 60" &
[1] 52645
LAUNCHER_PGID=52645
DAEMON_CMD_EXIT=0

$ ps ax -o pid,ppid,pgid,command | grep beam.smp
52742 52741 52742 .../beam.smp ...   # already its own pgid, distinct from 52645, before the launcher even printed DAEMON_CMD_EXIT

$ kill -9 -52645     # kill the ENTIRE launcher process group
$ ps -p 52645        # gone
$ ps ax -o pid,ppid,pgid,command | grep beam.smp
52742 52741 52742 .../beam.smp ...  # still alive, untouched

$ CS_HOME=... bin/consigliere_daemon eval 'Consigliere.CLI.doctor()'
daemon running (home: ...)
```

The daemon (pid 52742) had already moved into its own distinct process group before the `daemon` command even returned, and survived a `kill -9` of the entire launcher group with no special handling required -- unlike `nohup ... & disown`, which changes signal disposition but not process-group membership, and was the actual mechanism behind ADR-003's incident.

## Adversarial review

An independent fable-model audit was commissioned before implementing the LaunchAgent scenarios, specifically to pressure-test the decision to descope them in favor of the `herdr`/release/doctor-protocol replacement described above. It returned "proceed, with four specific adjustments," all since addressed:

1. The descope rationale needed to name what's actually lost (self-revival after a hard VM crash with nobody present, which `herdr` does not provide and `launchd`'s `KeepAlive` would have) rather than only "herdr replaces launchd." Folded into the sharpened revisit trigger in `docs/phase0-report.md` section 11.
2. Running `cs start` from inside an agent tool call risks repeating this project's own recorded incident (ADR-003's dead-owner incident, 213 revivals from a process that died with its bounded parent call). Fixed by proof rather than by code: live-verified that a release's `daemon` command survives its launching subshell's entire process group being killed with `-9`, the way `nohup ... & disown` did not -- see "Live evidence: process-group survival" above.
3. `mix release` is not a drop-in "free" CLI as originally assumed: `mix cs.doctor` does not exist in a release (Mix isn't shipped), and the default `RELEASE_DISTRIBUTION=sname` node naming would collide on `epmd` before `Home.Lock` ever runs, misattributing the failure and potentially colliding across genuinely different `CS_HOME`s. Fixed: `Consigliere.CLI.doctor/0` is release-reachable via `eval`, and `RELEASE_DISTRIBUTION=none` removes the collision risk entirely -- live-verified with two different `CS_HOME`s running concurrently with no false collision.
4. "Treat already-running as success" was not yet actually implementable from the CLI: two real bugs (`last_error.log` never cleared on a successful boot; a genuine non-forced crash was never recorded at all) meant `cs doctor` could not reliably distinguish the two cases the protocol above depends on. Both fixed (`Consigliere.Home.clear_error!/1`, `Consigliere.Application.record_boot_result/2`) and live-verified -- see scenario 4 above.

The audit also flagged the accept-queue issue (finding #1's minor note) that this spike's own subsequent live QA then independently reproduced for real, confirming it was load-bearing rather than cosmetic (see "A real bug this live QA found" above).
