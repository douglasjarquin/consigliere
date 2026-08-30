# F3 packaged manual QA

Date: 2026-08-30.

Target source head: `71593738cf6aae723c9208743405fa12a9dc7a03`.

Package input: `/Users/douglasjarquin/.herdr/worktrees/consigliere/cs-consigliere-local-v0-revival/.tmp/package-7159373.zxQ0gA`.

No package build, source checkout command, GitHub command, Mission/canary command, or shared Made-daemon lifecycle command was run in this lane.

## Package identity

Invocation from the repository worktree:

```text
PKG="$PWD/.tmp/package-7159373.zxQ0gA"
file "$PKG/bin/cs" "$PKG/bin/csd" "$PKG/libexec/consigliere_daemon/lib/consigliere_daemon-0.1.0/priv/cs-runner" "$PKG/libexec/consigliere_daemon/lib/consigliere_daemon-0.1.0/priv/cs-attempt" "$PKG/libexec/consigliere_daemon/erts-17.0.5/bin/erlexec"
shasum -a 256 <the same five files>
env -i PATH="$PKG/bin:/usr/bin:/bin" HOME=<fresh /tmp home> CS_HOME=<fresh /tmp CS home> CS_RELEASE="$PKG/libexec/consigliere_daemon" "$PKG/bin/cs" version --json
```

Observed package identity:

```text
cs: Mach-O 64-bit executable arm64
csd: Mach-O 64-bit executable arm64
cs-runner: Mach-O 64-bit executable arm64
cs-attempt: Mach-O 64-bit executable arm64
erlexec: Mach-O 64-bit executable arm64
dc99434b4f26a613b4f5838b053b12ed082079372ea5673c13f4f87ecf7e0f27  cs
8195ebf3c0b3a111a7a859c581115740fed50373d53fd489f3d2717db19a98e3  csd
4410804f502ab3fb4bb885685af07094dacb0d58e90eec49874487859a384051  cs-runner
3a5064c289f8ced3f80654d24db0d5daaebdd2c2f9acb642faf72b09bb0f4697  cs-attempt
0d58107509b1c59399cf3c9bdbf495b2f05f1fb4a5492c19cb886c65fb4c96d6  erlexec
cs version --json: {"cs":"0.1.0","protocol":1}
```

The package contained no `mix.exs` or `mix.lock` files.

## Fresh package-only lifecycle

Surface: installed package clients and OTP release, launched from `/tmp` in tmux.

Fresh homes: `HOME=/tmp/cs-f3-final-home.THXqWP` and `CS_HOME=/tmp/cs-f3-final-cs-home.XCjwpa`.

Exact invocation:

```text
tmux new-session -d -s cs-f3-final-qa-2 /bin/sh
env -i PATH=/Users/douglasjarquin/.herdr/worktrees/consigliere/cs-consigliere-local-v0-revival/.tmp/package-7159373.zxQ0gA/bin:/usr/bin:/bin HOME=/tmp/cs-f3-final-home.THXqWP CS_HOME=/tmp/cs-f3-final-cs-home.XCjwpa CS_RELEASE=/Users/douglasjarquin/.herdr/worktrees/consigliere/cs-consigliere-local-v0-revival/.tmp/package-7159373.zxQ0gA/libexec/consigliere_daemon CS_CSD_FORCE_BACKGROUND=1 /bin/sh
cd /tmp
cs version --json
csd migrate
csd start
cs ping
cs health
cs doctor
csd status
csd stop
csd stop
csd restart
cs ping
cs health
cs doctor
csd status
csd stop
csd stop
```

Concise redacted tmux observations:

```text
version: {"cs":"0.1.0","protocol":1}; exit=0
migrate: migrated /tmp/cs-f3-final-cs-home.XCjwpa/consigliere.db; exit=0
start: started home=/tmp/cs-f3-final-cs-home.XCjwpa; exit=0
ping: pong; exit=0
health: status=ok protocol=1 release=0.1.0 schema=2.026083012e+13 harness=Consigliere.Harness.Codex; exit=0
doctor: lock held pid=31789, probe/priv/api sockets live, codex auth absent, runner present; exit=0
status-before: owner=verified holder=31789, priv/api/boss live; exit=0
stop-1: stopped; exit=0
stop-2: stopped; exit=0
restart: restarted; exit=0
ping-after-restart: pong; exit=0
health-after-restart: status=ok protocol=1 release=0.1.0 schema=2.026083012e+13 harness=Consigliere.Harness.Codex; exit=0
doctor-after-restart: lock held pid=32003, probe/priv/api sockets live, codex auth absent, runner present; exit=0
status-after-restart: owner=verified holder=32003, priv/api/boss live; exit=0
stop-3: stopped; exit=0
stop-4: stopped; exit=0
```

Identity-safe and cleanup assertions:

```text
pid=31789 absent
pid=32003 absent
pid_residue=absent
priv.sock=absent
api.sock=absent
boss.sock=absent
owner_json=absent
package_processes=absent
```

Cleanup receipt:

```text
/usr/bin/trash /tmp/cs-f3-final-home.THXqWP /tmp/cs-f3-final-cs-home.XCjwpa
home_after_trash=absent
cs_home_after_trash=absent
```

## Verdict

Overall verdict: **PASS**.

## manualQa

### surfaceEvidence

| scenario id | criterion reference | surface | exact invocation | verdict | artifactRefs |
|---|---|---|---|---|---|
| F3-PKG-IDENTITY | exact source-head package identity | retained installed package | `file` and `shasum -a 256` on the five package artifacts, then `env -i ... cs version --json` | PASS: native artifact types, recorded hashes, protocol, and version matched the exact-head package identity. | PKG-F3, REPORT-F3 |
| F3-LIFECYCLE | installed package lifecycle | package-only clients and OTP release in fresh `/tmp` homes | tmux `/bin/sh` from `/tmp`; `env -i ... cs version --json; csd migrate; csd start; cs ping; cs health; cs doctor; csd status` | PASS: all commands exited 0; ping, health, doctor, and verified status were live. | TMUX-F3, REPORT-F3 |
| F3-RESTART-STOP | identity-safe stop/restart/repeated stop | same fresh package-only runtime | `csd stop; csd stop; csd restart; cs ping; cs health; cs doctor; csd status; csd stop; csd stop` | PASS: repeated stop converged, restart reacquired verified ownership with a different holder PID, and all post-restart probes passed. | TMUX-F3, CLEAN-F3, REPORT-F3 |
| F3-CLEANUP | cleanup and process isolation | `/tmp` homes, sockets, owner state, and process table | final residue assertions, `ps` checks for holder PIDs and package path, then `/usr/bin/trash` and existence checks | PASS: both owner PIDs, sockets, owner state, package processes, and temporary homes were absent. | CLEAN-F3, REPORT-F3 |

### adversarialCases

| scenario id | criterion reference | adversarial class | expected behavior | verdict | artifactRefs |
|---|---|---|---|---|---|
| F3-AC-IDENTITY | package identity | stale or substituted package | Do not accept a package whose artifact types, hashes, or installed version do not match the exact source-head package. | PASS: all five hashes/types and `cs version --json` matched. | PKG-F3, REPORT-F3 |
| F3-AC-BOUNDARY | package-only boundary | source/build-tool leakage | Installed execution must work with package-only `PATH` and no Mix project files. | PASS: commands ran from `/tmp` under `env -i`; `mix.exs` and `mix.lock` were absent. | PKG-F3, TMUX-F3, REPORT-F3 |
| F3-AC-REPEAT-STOP | lifecycle convergence | repeated stop after a stopped owner | Stop must be idempotent and must not leave runtime residue. | PASS: both first and second stop returned 0, and both final repeated stops returned 0. | TMUX-F3, CLEAN-F3, REPORT-F3 |
| F3-AC-OWNER-IDENTITY | identity-safe lifecycle | restart and stale owner identity | Restart must report a newly verified owner, and the old/new owner PIDs must be absent after final stop. | PASS: holder changed from 31789 to 32003; both were absent after stop. | TMUX-F3, CLEAN-F3, REPORT-F3 |
| F3-AC-ISOLATION | package-only isolation | accidental shared-daemon or source access | The lane must use only its fresh `CS_HOME` and retained package, without shared Made-daemon lifecycle actions. | PASS: fresh homes and package paths were used; no shared-daemon or canary command was invoked. | TMUX-F3, CLEAN-F3, REPORT-F3 |
| F3-AC-CANARY | operator-controlled canary | duplicate real canary | Final QA must not create a Mission or rerun the completed real canary. | PASS: no Mission, attempt, Codex, or canary invocation occurred. | REPORT-F3 |

### artifactRefs

| id | kind | description | path |
|---|---|---|---|
| PKG-F3 | package identity receipt | Exact-head package prefix, native artifact types, SHA-256 values, and installed version. | `/Users/douglasjarquin/.herdr/worktrees/consigliere/cs-consigliere-local-v0-revival/.omo/evidence/consigliere-local-v0-revival/manual-qa-final-7159373.md` |
| TMUX-F3 | terminal transcript receipt | Fresh tmux package-only lifecycle with migration, start, probes, restart, and repeated stops. | `/Users/douglasjarquin/.herdr/worktrees/consigliere/cs-consigliere-local-v0-revival/.omo/evidence/consigliere-local-v0-revival/manual-qa-final-7159373.md` |
| CLEAN-F3 | cleanup receipt | Owner PID absence, socket/owner residue absence, package process scan, Trash operation, and post-cleanup absence. | `/Users/douglasjarquin/.herdr/worktrees/consigliere/cs-consigliere-local-v0-revival/.omo/evidence/consigliere-local-v0-revival/manual-qa-final-7159373.md` |
| REPORT-F3 | final manual QA matrix | Full bounded F3 report for exact source head `71593738cf6aae723c9208743405fa12a9dc7a03`. | `/Users/douglasjarquin/.herdr/worktrees/consigliere/cs-consigliere-local-v0-revival/.omo/evidence/consigliere-local-v0-revival/manual-qa-final-7159373.md` |
