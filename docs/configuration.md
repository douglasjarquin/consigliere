# Configuration

Single owner of the operational-home layout and configuration schemas.
Each producing script's header and help own exact child fields and mutation mechanics.

## Homes

`CS_HOME` selects an instance's private `config/`, `host/`, `data/`, `state/`, and `projects/`.
Scripts always come from their tracked code root (`CS_ROOT`, the repo checkout).
The main home is the repo checkout itself; each capo has a persistent isolated `CS_HOME` under `${CS_CAPOS_ROOT:-~/.consigliere/capos}/<id>` - a plain detached git worktree of this repo, never a herdr-managed worktree (a capo home must survive server restarts and empty workspaces).

Test and script overrides: `CS_ROOT_OVERRIDE`, `CS_STATE_OVERRIDE` narrow a single script's resolution; production flows never set them.

## Herdr layout

- One herdr session: `default` (labs excepted; see `bin/cs-herdr-lab.sh`).
- One home workspace per home: label `consigliere` for the main home, `capo-<id>` for capo homes.
- One workspace per task, created by `herdr worktree create` and labeled with the task id; the root pane is the task pane.
- `CS_HERDR_SESSION` overrides the session for lab work only.
- Verified herdr behavior and gaps: `docs/herdr.md`.

## config/ and host/ - the user-owned tree and its machine-local sibling (LOCAL, gitignored)

`config/` is the one directory a person owns, backs up, and restores: `cp -a <home>/config`, no exclusions, and restore on a new machine is that same copy.
`host/` is a top-level sibling, not part of the user tree: machine-local runtime configuration, mostly script-written, correct only on the machine that wrote it.
It is never backed up, restored, or propagated; on a new machine run `bin/cs-doctor.sh` and fill in `host/` fresh.
Prose and records use `.md`; settings use `.conf`; the extension marks the format, never the tier - `config/` holds three genuinely portable `.conf` files, and every other `.conf` file is machine-local and lives in `host/`.
`bin/cs-migrate-config.sh` owns the one-shot move from the pre-2026-08 layout, and the fail-closed gate in `bin/cs-root-lib.sh` refuses every script while any old-name path exists.

| file | tier | semantics |
|---|---|---|
| `config/boss.md` | portable | boss preferences and working style; inspect-then-update |
| `config/boss-shared.md` | portable | main-authoritative shared boss preferences; source of the capo propagation |
| `config/learnings.md` | portable | curated fleet-local operational facts |
| `config/memory-archive.md` | portable | the cold tier of this home's curated memory: entries `skills/vault` retired from `boss.md`, `boss-shared.md`, or `learnings.md` because they went stale, were proved obsolete, or were evicted over budget with the boss's approval. Each entry keeps its provenance (original file, date, reason) in a trailing HTML comment. It lives in the backed-up user-owned tree precisely because archive-never-delete would be a lie in a disposable one, but nothing reads it at session start, so it costs no startup memory until a sweep deliberately opens it. `skills/vault` owns the tier markers, the decay clocks, and what may move here; `bin/cs-vault-cascade.sh` reports its size per home and never writes it |
| `config/projects.md` | portable | fleet navigation registry with standing per-project posture |
| `config/boards.md` | portable | per-project GitHub Projects board mapping (schema below) |
| `config/backlog.md` | portable | the durable queue; written by tasks-axi (`.tasks.toml` owns schema) |
| `config/done-archive.md` | portable | tasks-axi done archive, pinned by `.tasks.toml` |
| `config/note-archive.md` | portable | tasks-axi body archive; an internal sibling name tasks-axi creates beside the backlog |
| `config/charter.md` | portable, capo homes only | the capo's filled charter brief |
| `config/bossless-ack.md` | portable | per-project bossless-mode acknowledgment / kill switch; `bin/cs-afk-start.sh`'s own header owns the record format and fail-closed parsing |
| `config/backlog-backend.conf` | portable | absent or `tasks-axi` = tasks-axi against `config/backlog.md`; `manual` = hand-edit the markdown |
| `config/permission-mode.conf` | portable | optional narrower claude launch permission mode; absent = full autonomy; `bin/cs-harness-lib.sh` owns the two-column schema below. This is a Claude ACCOUNT policy, not a machine property - the record is `<harness> <mode>` with no machine-specific content, so the same file is correct verbatim on every machine that account uses; do not re-derive it as host-specific |
| `config/wedge-alarm.conf` | portable | wedge-alarm active-alert directives, read through `bin/cs-prompt-lib.sh` by every guarded-prompt caller (currently `bin/cs-activate.sh`, for a failing stretch past `CS_ACTIVATE_WEDGE_MAX_SECS`); absent = auto (macOS Notification Center when available, degrading elsewhere). A boss preference, boss-authored only; the directives are channel selectors that adapt per OS, so the file is portable. The one non-portable use is a `command:` directive naming a machine-local path - keep such a value out of shared dotfiles |
| `host/capos.md` | host | capo routing table; every record embeds an absolute machine-local home path |
| `host/harness.conf` | host | pins the root harness (`codex` or `claude`) regardless of environment |
| `host/upstream.conf` | host | path of the firstmate checkout for `/upstream-review`; absent = `../firstmate` |
| `host/activation.conf` | host | per-home activation scope: `always`, `afk-only`, or `off`; absent = `always`, because a turn that ends depends on activation to start the next one; `bin/cs-activate.sh` owns the policy, and `bin/cs-home-seed.sh --help` owns capo seed and bootstrap convergence |
| `host/herdr-plugin/herdr-plugin.toml` | host | generated manifest for this home's herdr push-event plugin, written and linked by `bin/cs-herdr-event-plugin.sh` (its header owns the mechanics). Machine-local by nature: herdr's plugin registry is global to the user and lives in `~/.config/herdr`. Never hand-edited; re-run `install` to regenerate |
| `host/telemetry.conf` | host | optional per-home turn telemetry switch: `enabled true\|false` plus an optional `retain_days <1..3650>`; absent = disabled, malformed = disabled with a doctor diagnostic. `docs/telemetry.md` owns the whole contract. Never propagated into a capo home, which enables its own |

Symlink policy, established empirically (2026-08-06, tasks-axi 0.2.x):

- `boss.md`, `boss-shared.md`, `learnings.md`, `memory-archive.md`, `projects.md`, `boards.md`, and the three portable `.conf` files are read-only to scripts and safe to symlink out to a dotfiles repository.
- `backlog.md`, `done-archive.md`, `note-archive.md`, and `host/capos.md` are rewritten by rename (tasks-axi and the registry writers), which replaces a symlink with a regular file and silently forks the content; they must be real files, and the doctor fails when one is a symlink.
- A `host/` entry whose symlink target resolves outside the home defeats the host tier (the `capos.md`-across-two-machines mistake); the doctor fails on it.

Inheritance into capo homes: `config/boss-shared.md` is propagated read-only, and `config/backlog-backend.conf` is copied at seed time; nothing else is inherited, and nothing in `host/` ever propagates.
Capo activation is local rather than inherited; see `bin/cs-home-seed.sh --help` for its seed and bootstrap convergence contract.
The main-side source of either may be a symlink that resolves to a regular file, because propagation only reads it; an unresolved symlink stops propagation instead of mirroring absence.
The capo-side destination must be a plain regular file, because propagation writes there and following a link out of the capo home is exactly what that check prevents.
`bin/cs-inherit-lib.sh` owns the allowlist.

### Permission mode

`config/permission-mode.conf` is optional and local to one Consigliere home.
It exists for a claude home on a Claude account whose managed policy forbids `--dangerously-skip-permissions`: without it, every soldier pane would start in the harness default and need a human to widen it by hand.
One non-comment line has exactly two whitespace-separated fields:

```text
<harness> <mode>
```

`harness` is `claude`; `codex` is rejected because its autonomy flag is not configurable.
`mode` is `auto`, `acceptEdits`, or `bypassPermissions`.
Blank lines and lines whose first field begins with `#` are ignored.

```text
# harness mode
claude auto
```

An absent file, or a file with no record for the resolved harness, keeps the harness default: full autonomy through `--dangerously-skip-permissions` (claude) or `--dangerously-bypass-approvals-and-sandbox` (codex).
A configured mode replaces that flag; exactly one of the two ever reaches a launch.

Claude's remaining modes are refused deliberately.
`plan` cannot edit files at all, and `manual` and `dontAsk` park on a prompt no supervisor can answer, so each one wedges an unattended pane.
Every record is validated, not just the one matching the running harness, so a typo stops the next dispatch instead of silently doing nothing.
A malformed file, an unknown harness, an unusable mode, or a duplicate record fails the launch rather than falling back to full autonomy.

The mode is resolved from the home that builds the launch, so a capo launched by a configured home inherits that home's mode.
`config/permission-mode.conf` itself is not seeded into a capo home; set it there too if that capo spawns its own soldiers.

Operational consequence: under `auto` or `acceptEdits` a soldier can still stop on a permission prompt.
That pane looks busy rather than failed, so it surfaces through the ordinary stale-liveness path in `docs/supervision.md` instead of as an immediate failure.

## data/ and state/

`AGENTS.md` section 2 owns the every-session file tree; this section owns field-level reference detail; producing scripts own mutation:

- `config/boards.md` - per-project GitHub Projects (v2) board mapping for the `contracts` and `casino` skills, kept beside `config/projects.md` and keyed by the same project name. Blank lines and `#` comments ignored; every other line is `<project> <owner> <number> [ready-label] [in-progress-label] [status-field] [inbox-label] [backlog-label]`. Labels/field default to `Ready` / `In Progress` / `Status` / `Inbox` / `Backlog`; use `_` for spaces in a label token. `<owner>` is a user/org login or `@me`. `bin/cs-board.sh` reads it; the board mapping is optional (only projects worked via the board need a line), and the Inbox/Backlog columns matter only to `casino`.
- `data/sweeps.md` - the boss's standing intent to work a project's board, so a sweep outlives the session that started it.
  Written only by `bin/cs-board-watch.sh`; blank lines and `#` comments are ignored, and every other line is `<project> <lane-cap> <resurface-secs> <green-pr-policy> <armed-utc>`.
  `<green-pr-policy>` is `hold-green-prs` or `release-green-prs`, with hold as the ordinary default.
  Each record arms `state/sweep-<project>.check.sh`, an ordinary hash-bound custom watcher check that reports column depth and never moves a card.
  `cs-board-watch.sh sync` converges the two in both directions and runs at every locked session start.
- `state/sweep-<project>.board-seen` - the sweep poll's own memory: last reported Ready count, Inbox count, and epoch, one per line. It is what makes the poll silent on a column consigliere shrank and loud on one the boss grew. Deleted on arm and disarm; safe to delete by hand, which only costs one extra report.
- `state/<id>.meta` - written by `cs-spawn.sh`: `workspace=`, `pane=`, `worktree=`, `project=`, `kind=` (ship|scout|capo), `harness=` (codex|claude, inherited from the root session). No model or reasoning level is recorded, because the harness selects both.
  A `kind=ship` task also records the posture its spawn stated explicitly: `mode=` (no-mistakes|direct-PR|local-only) and `yolo=` (on|off).
  A `kind=scout` records NEITHER, because a report deliverable has no mode to honour and no approval posture to apply, which is why `cs-promote.sh` is where a promoted scout first states both.
  `kind=capo` records `mode=capo`, `yolo=off`, and `home=`.
  `cs-spawn.sh` also records `issue=` for board-driven work and `headless=1` for a headless scout (`codex exec` / `claude -p`); `cs-pr-check.sh` appends `pr=` and any available `pr_head=`.
- `state/<id>.status` - appended by soldiers; wake events, never current state. `bin/cs-classify-lib.sh` owns the verb vocabulary.
- Pending-reply records (including capo-decision-escalation records) - see `bin/cs-pending-reply-lib.sh`'s `SCHEMA-OWNER` header comment for the full field list.
- Auto-decision ledger (`data/<task_id>/auto-decisions.log`) - see `bin/cs-auto-decision-lib.sh`'s `SCHEMA-OWNER` header comment for the full field list.
- `state/<id>.control-relaunch` - the agent-control plane's relaunch transaction journal, in the same flat key=value format as the meta file; `bin/cs-control.sh --help` owns the fields and `docs/agent-control.md` the phase sequence. A journal in a non-terminal phase blocks the next relaunch until `--clear-journal` acknowledges it, which sets it aside as `state/<id>.control-relaunch.abandoned`. Both are removed by teardown; deleting one by hand only costs that acknowledgement.
- `state/.decision-cursor-<task>` - per-status-file byte cursor plus folded open-decision set, written only by `bin/cs-classify-lib.sh`'s `status_open_decisions_incremental` so the wake drain's fleet-wide open-decision scan folds only newly appended status bytes. Removed by teardown with the other watcher markers, along with any `.read.*` / `.tmp.*` staging temps a killed drain left beside it; always safe to delete by hand, which only costs one full re-fold of that task's status log.
  If `state/` is unwritable so no cursor can be staged at all, the drain falls back to the unbounded whole-file fold for that call rather than reporting nothing open.
- `data/telemetry/turns.jsonl` - append-only JSON Lines turn telemetry for this home, written only while `host/telemetry.conf` enables it, with `state/.telemetry-crumbs-<pid>-<hash>` (turn-scoped breadcrumbs, keyed to the harness process and its reuse-proof identity, discarded once older than `CS_BUSY_TURN_MAX_SECS`) and `state/.telemetry-cursor-<session>` (per-harness-session transcript byte offset plus the effort and model that session last stated) as its disposable working state. `docs/telemetry.md` owns the schema, the folding rules, retention, and the privacy contract; `bin/cs-telemetry-lib.sh` implements them.
- `state/.herdr-events` - the push-event spool herdr's own plugin hook appends to, one `<kind><TAB><pane><TAB><workspace><TAB><status><TAB><agent>` record per `pane.agent_status_changed` edge, size-capped and rotated by truncation. Its PRESENCE is also the watcher's capability gate, so it is created only once herdr accepts the plugin link. Deleting it costs at most the edges until the next one: while the plugin stays linked, the next `pane.agent_status_changed` edge recreates the spool and the capability gate flips straight back on, with no reinstall.
Only `bin/cs-herdr-event-plugin.sh uninstall` durably disables the transport and drops the watcher back to pure polling.
- `state/.herdr-events-cursor` - the watcher's byte offset into that spool, which is what lets edges that fired while no watcher ran still be delivered. Safe to delete: the next drain re-reads the spool from the start, costing at most a repeated escalation the per-pane dedupe marker already absorbs.
- `state/.wake-queue` - `epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload`; `bin/cs-wake-lib.sh` owns it.
- `state/.wake-queue.drain.*` - a drain's rotation batch; one still on disk holds wake records from a drain that never committed, and the next drain adopts, replays, and retires it (`docs/supervision.md`, "Drain durability", owns the mechanism).
  Never delete one by hand: the queue no longer carries those records.
- `state/.wake-queue.restore.*` - staging temp for putting an interrupted drain's batch back on the queue; a leftover is pure litter and the next drain removes it.
- `state/.session-start-complete` - the lock owner's pid, written atomically by `bin/cs-session-start.sh` only when a full locked startup reached its final stage, and cleared when the next full locked startup begins. `bin/cs-sessionstart-run.sh` re-emits on a clear or compact only when this record matches the current lock owner in its own ancestry, so a startup killed mid-sweep is finished before any re-emit. Safe to delete by hand, which only costs one full startup on the next clear or compact.
- `state/.startup-network.*` - the deferred network stage's own records, owned by `bin/cs-startup-network.sh` (its header owns the exact fields).
  `.status` is the key=value source of truth for what ran and how it ended, `.report` is the current result - a `covered=<phases>` line naming the checks that run speaks for, then the sweep output byte for byte as `bin/cs-bootstrap.sh` produced it - `.claim` names the session start that intends to print it inline, `.delivered` is the one durable acknowledgement that suppresses its wake - written only by a reader that actually printed the result, and cleared only by a publish that actually replaced it - and `.lock` serializes publication, acknowledgement, and the wake decision.
  `.timings` is where that stage spent its time - one elapsed-time record per check owner and per item inside it, all offset from one shared origin, in `bin/cs-timing-lib.sh`'s format - published by the same publish for every outcome, including a run that timed out or failed, where the step that never finished is the one with no record; only `cs-startup-network.sh report` prints it, so the digest is unaffected.
  `.pending/` holds whole results that finished and were never read, one per file in the same format and named so plain name order is oldest first; results are never merged, so a publish that would land on an unread result moves it here first.
  A harvest prints that store ahead of the current result and empties it, and the store keeps only its most recent few results, disclosing by number any older ones it dropped.
  Safe to delete by hand between sessions: the sweeps are idempotent detectors, so the next session start re-derives every finding.
- `state/.home-pane` - the pane id of THIS home's own agent, written by `bin/cs-session-start.sh` from `HERDR_PANE_ID` (the one place that runs inside the home's own pane). A durable HINT, never an identity: herdr recycles pane ids, so `bin/cs-activate.sh` revalidates that the pane still exists, still runs an agent, and is still rooted in this home before it will prompt anything.
- `state/.last-activation` - cooldown stamp for `bin/cs-activate.sh`; also the recursion guard, since the turn activation starts drains the queue and may append more wakes.
- `state/.activate-busy-since` - `bin/cs-activate.sh`'s continuous non-empty-queue stamp, cleared the moment the queue is seen empty; ages past `CS_ACTIVATE_BUSY_MAX_SECS` fire activation even while the queue stays too busy to ever go quiet.
- `state/.activate-fail-since` - `bin/cs-activate.sh`'s continuous failing-delivery stamp, cleared on a success or an empty queue; while present the retry floor is `CS_ACTIVATE_RETRY_SECS` instead of `CS_ACTIVATE_COOLDOWN_SECS`, and ages past `CS_ACTIVATE_WEDGE_MAX_SECS` fire the wedge alarm once per stretch.
- `state/.checkpoint-turn` - the per-turn checkpoint counter. `bin/cs-watch-checkpoint.sh` writes it on entry and refuses (exit 3) if it is already there; `bin/cs-turnend-guard.sh` clears it at every turn end and `bin/cs-session-start.sh` clears one left by a turn that died mid-flight. `docs/supervision.md` owns why the limit is mechanical rather than written down. Safe to delete by hand, which only permits one extra checkpoint in the current turn.
- `state/.activation-stalled` - durable marker that this home cannot self-activate (pane gone, pane recycled to another home, or no agent). Its whole purpose is that a home with the parent removed from the loop fails loudly instead of rotting.
- `state/procevent/` and `state/procevent-inbox/` - armed blocking sources and their captured results; see `## Process events` below.
- `state/.subsuper-daemon-beat` - dead. It was the away-mode daemon's proof that it was supervising, written by `bin/cs-daemon.sh` at the BOTTOM of each loop pass. `bin/cs-monitor.sh` dropped the stand-down branch that read it, and `bin/cs-daemon.sh` itself is now deleted, so nothing writes or reads this file anymore.
- `state/.subsuper-inject-wedged` - durable wedge marker, written once per continuous failing stretch by `bin/cs-activate.sh` (past `CS_ACTIVATE_WEDGE_MAX_SECS`); `bin/cs-afk-return.sh` reads it as catch-up evidence on the boss's return.

## Process events

A process event lets consigliere wait on a BLOCKING external command without holding a conversational turn.
The driving case is `lavish-axi poll <artifact>`, which long-polls for a human's feedback on a review artifact; `docs/lavish.md` records the verified facts that path depends on.
`bin/cs-procevent.sh --help` owns every command, flag, and record field; this section owns the layout and the guarantees.

The subsystem adds no second notification control plane.
A completed result becomes an ordinary `check` wake on the durable queue, which the bounded checkpoint, the persistent monitor's activation path, and session start already read.

### Layout

| path | owner | contents |
|---|---|---|
| `state/procevent/<id>.source` | `cs-procevent.sh register` | `adapter=`, `argc=`, `argv:` then one argument per line, mode 0600. argv is executed directly, so there is no shell surface. |
| `state/procevent/<id>.runner` | the runner | the runner leader's pid while it is running |
| `state/procevent-inbox/<id>.<seq>.result` | the runner | one captured result, mode 0600. Bounded by `CS_PROCEVENT_MAX_OUTPUT_BYTES`. |
| `state/procevent-inbox/<id>.<seq>.adapter` | the runner | the adapter that produced it, renamed into place before the result |
| `state/procevent-inbox/<id>.<seq>.handled` | `cs-procevent.sh handled` | the one durable acknowledgement for that generation |
| `${XDG_STATE_HOME:-~/.local/state}/consigliere/procevent-claims/<id>.claim` | the runner | machine-wide ownership: home, runner pid, generation token, process identity, registration dir, registration identity, `active` or `terminal` |
| `.../procevent-claims/<id>.lock` | all of the above | the per-source mutual-exclusion boundary |

The claim root is machine-wide, not per home, because a main home and its capo homes share one machine and one source store.
`<id>` is derived by the adapter from canonical PHYSICAL source identity, never from a display string, so two names for one artifact cannot become two owners racing destructive polls.

### Guarantees

- **Capture before publish.** Once the child has exited and its output has been read, that output is stored at mode 0600 and renamed into place BEFORE any event referencing it is published.
- **Identity-only events.** A wake line is `check: procevent <adapter> <id> <seq>`. No source output, path, or caller-supplied text can appear on it; the result stays a file.
- **Re-announcement until acknowledged.** A captured result with no `handled` record stays eligible for re-announcement across any number of drains and restarts.
  `handled` is the only terminal state, is atomic, distinguishes first-time from repeat, and refuses unless the matching result and adapter records exist.
- **One owner per canonical source.** A live owner is never displaced.
  A crashed leader whose process group still has members is not stale: reconcile stops that group and releases its generation before any replacement starts, and keeps the claim when it cannot prove the group stopped.
- **Adapter-owned retirement.** The runner never inspects a result.
  It calls `bin/cs-procevent-<adapter>.sh terminal <result-file>` and treats exit 0 as the only terminal verdict; anything else, including a missing command, keeps the source armed.
- **Supervision registration.** An armed source counts as work needing supervision in `bin/cs-supervision-lib.sh`, so `bin/cs-guard.sh` and `bin/cs-turnend-guard.sh` will not tell a home whose only work is an armed source that supervision is unnecessary.
- **Home retirement safety.** `bin/cs-teardown.sh` runs `cs-procevent.sh retire-home` against a capo home before removing it and refuses if anything is left, because a leaked blocking child against a shared external source is real harm.

What it does NOT prove: anything about the source side of the handoff.
`lavish-axi poll` clears the human's feedback before returning it, so a result lost between that clearing and the runner reading the process output is unrecoverable.
Never describe this path as at-least-once, no-loss, or lossless.

## Environment variables

| variable | consumer | semantics |
|---|---|---|
| `CS_HOME` | all scripts | home selector; defaults to the repo root |
| `CS_HERDR_SESSION` | cs-herdr-lib | herdr session; labs only, defaults to `default` |
| `CS_CAPOS_ROOT` | cs-home-seed | capo home pool root; default `~/.consigliere/capos` |
| `CS_WATCH_CHECKPOINT` | cs-watch-checkpoint | bounded foreground checkpoint seconds; default 180 |
| `CS_OPEN_DECISIONS_CAP` | cs-wake-drain | maximum open decisions printed per drain; default 32; omitted decisions are marked |
| `CS_OPEN_DECISIONS_READ_PROBE` | cs-classify-lib | test-only observability seam, unset in production: a file the cursor-backed fold appends `<status-file><TAB><bytes-folded>` to per call, so a test can assert the drain scan stays bounded by new appends |
| `CS_CHECK_TIMEOUT` | cs-watch | per-check timeout for registered `state/<id>.check.sh` |
| `CS_STALE_ESCALATE_SECS` | cs-watch | wedge escalation threshold |
| `CS_BUSY_TURN_MAX_SECS` | cs-watch | how long a pane may run busy with no completed turn before it enters the wedge timer; default 3600 |
| `CS_SESSION_START_TIMEOUT` | cs-session-start | hard bound in seconds for the whole digest, which runs as one bounded child because the session-open hooks block session initialization while it runs; on expiry the parent prints the STARTUP TRUNCATED banner naming the stalled stage and every stage that never ran, and still exits 0. A host where the bound cannot be established at all (an unusable `TMPDIR`) gets the separate STARTUP DID NOT RUN banner instead, because a digest that never started is not a digest that stalled. Default 120 |
| `CS_TIMEOUT_MECHANISM_OVERRIDE` | cs-timeout-lib | set to `bash` to force the dependency-free watchdog fallback; tests use it to exercise the bound on hosts that ship timeout/gtimeout/perl |
| `CS_BOOTSTRAP_LOCKED` | cs-bootstrap | set alongside `CS_BOOTSTRAP_DETECT_ONLY=1` when the sweeps are skipped because THIS session already ran them while holding the lock (a `--reemit`), so tangle repair ownership stays with this session instead of deferring to a lock holder that is itself |
| `CS_BOOTSTRAP_NETWORK` | cs-bootstrap | `all` (default, and any unrecognized value), `skip` (every local step, no network one), or `only` (every network step and nothing else). The two halves are a strict partition of the unsplit run; `bin/cs-session-start.sh` passes `skip` and `bin/cs-startup-network.sh` runs `only` |
| `CS_BOOTSTRAP_NETWORK_LOCK_PID` | cs-bootstrap | the `state/.lock` owner a deferred worker captured while that session still held the lock; each network mutating sweep re-verifies it and reports a skip rather than sweeping on behalf of a session that has gone away |
| `CS_STARTUP_NETWORK_TIMEOUT` | cs-startup-network | one aggregate hard bound in seconds for the whole deferred network stage, which runs outside `CS_SESSION_START_TIMEOUT` in its own process group. Hitting it is reported as a `NETWORK_CHECKS:` line, never as silence. Default 120 |
| `CS_STARTUP_MEMORY_MAX_BYTES` | cs-session-start, cs-vault-cascade | per-file budget for `config/boss.md`, `config/boss-shared.md`, and `config/learnings.md`; over budget is reported in the digest, never truncated. The vault cascade applies the same per-file budget to each capo home it reports. Default 8192 |
| `CS_VAULT_CASCADE_STEP_TIMEOUT` | cs-vault-cascade | per-home hard bound in seconds for one cascade step; a home that exceeds it is reported as an exception and the sweep continues. Default 20 |
| `CS_VAULT_CASCADE_REGISTRY_BYTES` | cs-vault-cascade | max bytes read from `host/capos.md` by the cascade's registry walk. Default 65536 |
| `CS_SESSION_START_STATUS_TAIL` | cs-session-start | `state/*.status` lines printed per task in the session-start digest; default 5; each line is capped by `bin/cs-line-cap-lib.sh` |
| `CS_SESSION_START_QUEUED_LIMIT` | cs-session-start | plain queued backlog rows in the session-start digest; default 20; done rows are never listed |
| `CS_SESSION_START_ACTIVE_LIMIT` | cs-session-start | in-flight, held, and blocked backlog rows per group in the session-start digest; default 40; each row is shown in full and any remainder is disclosed with the targeted follow-up that prints the rest; queued public-followup rows are outside this bound and always print in full |
| `CS_PAUSE_RESURFACE_SECS` | cs-watch | declared external-wait recheck cadence |
| `CS_EVENT_SPOOL_TICK` | cs-watch | how often the bounded event wait re-reads the spool, in seconds; default 0.5. The direct trade between blocked-escalation latency and the idle cost of a watcher with panes but no events - each tick is one `stat` plus the `sleep` |
| `CS_EVENT_SPOOL_MAX_BYTES` | cs-herdr-event-lib | size cap for `state/.herdr-events`; default 262144. An append past the cap TRUNCATES the spool, so the edges in it are dropped rather than delivered; the watcher's level reconcile is what covers that gap |
| `CS_EVENT_PLUGIN_DISABLE` | cs-herdr-event-plugin | set to `1` to make install and uninstall no-ops that report `disabled`. herdr's plugin registry is global to the user, so `tests/lib.sh` sets it for every suite to keep a throwaway temp home out of the developer's real registry |
| `CS_BOARD_SWEEP_LANES` | cs-board-watch | default lane cap baked into a new sweep record; default 3, matching the `contracts` skill |
| `CS_BOARD_SWEEP_RESURFACE` | cs-board-watch | default seconds before a still-full column is reported again; default 1800. Only a default for `arm`; each record stores its own value |
| `CS_SPAWN_LAUNCH_WAIT_SECS` | cs-spawn | seconds to wait for an agent to actually appear after the launch line is delivered, before treating the launch as swallowed; default 60 |
| `CS_SPAWN_HUMAN_GATE_SECS` | cs-spawn | seconds a freshly launched agent may sit in herdr's native `blocked` state before the spawn reports it out loud; short on purpose since this window only has to outlast a startup transient; default 10 |
| `CS_SPAWN_BASE_FRESHNESS_TIMEOUT_SECS` | cs-spawn | hard bound in seconds for the pre-branch base-freshness refresh through `bin/cs-fleet-sync.sh` when no `--base` was given; on expiry the spawn warns loudly and proceeds on the local HEAD; default 25 |
| `CS_SPAWN_CODEGRAPH_TIMEOUT_SECS` | cs-spawn | hard bound in seconds for the `codegraph init <worktree>` prep call at spawn and relaunch; on expiry the spawn warns loudly and proceeds with no codegraph index in the worktree; default 10, see `docs/codegraph.md` for the measurement behind it |
| `CS_SPAWN_CODEGRAPH_PREP` | cs-spawn | set to `off` to disable the codegraph index prep step entirely; default on |
| `CS_CONTROL_INTERRUPT_WAIT_SECS` | cs-control-lib | seconds to wait for a cancelled turn to actually stop before the interrupt is reported unconfirmed; default 15 |
| `CS_CONTROL_EXIT_WAIT_SECS` | cs-control-lib | seconds to wait for the agent process to leave the pane after the exit command; default 30 |
| `CS_CONTROL_EXIT_SETTLE` | cs-control-lib | pre-Enter settle for a harness whose completion popup would swallow the exit command's Enter (codex); default 1.5 |
| `CS_CONTROL_RESUME_WAIT_SECS` | cs-spawn --relaunch | seconds to wait for a resumed agent before falling back to a cold launch; default `CS_SPAWN_LAUNCH_WAIT_SECS`. The fallback also needs the pane to be positively agent-free, so a slow resume is refused rather than double-launched |
| `CS_CONTROL_RESUME_GRACE_SECS` | cs-spawn --relaunch | seconds before an agent-free pane counts as "the harness had nothing to resume" rather than "it has not started yet"; default 6 |
| `CS_CONTROL_RESUME_CONFIRM_SECS` | cs-spawn --relaunch | seconds a detected agent must still be there, with a readable agent process, before a launch counts. A harness with nothing to resume runs for a moment before printing its refusal, which is long enough for herdr's detector to see an agent; default 4 |
| `CS_ACTIVATE_QUIET_SECS` | cs-activate | the wake queue must have been still this long before activating, so one burst of wakes produces one turn; default 180 in the main home and 60 in a capo home, because the longer window is what shrinks the check-then-act composer race in the pane the boss types into |
| `CS_MONITOR_BIN`, `CS_MONITOR_DETACH_BIN` | cs-monitor-lib | monitor and detacher overrides, tests only |
| `CS_MONITOR_STALE_SECS` | cs-monitor-lib | a `state/.last-monitor-beat` older than this counts as no monitor at all and triggers a revival; default 60 |
| `CS_ACTIVATE_COOLDOWN_SECS` | cs-activate | minimum seconds between activations in a home after a SUCCESS; also the recursion guard; default 600 |
| `CS_ACTIVATE_BUSY_MAX_SECS` | cs-activate | continuous non-empty-queue age that fires activation anyway, for a queue that refills faster than `CS_ACTIVATE_QUIET_SECS` ever goes still; default 300 |
| `CS_ACTIVATE_RETRY_SECS` | cs-activate | minimum seconds between attempts while the last delivery FAILED, instead of the full cooldown; default 15 |
| `CS_ACTIVATE_WEDGE_MAX_SECS` | cs-activate | continuous failing-delivery age that fires the wedge alarm once per stretch; default 300 |
| `CS_PROMPT_CONFIRM_WAIT_MS` | cs-prompt-lib | ms to wait for the idle->working transition that proves a prompt was delivered; default 8000 |
| `CS_WEDGE_ALARM_CHANNEL` | cs-prompt-lib | overrides `config/wedge-alarm.conf` with one directive (`off`, `auto`, `osascript`, `herdr`, `command:<cmd>`); shared by every guarded-prompt caller (currently `bin/cs-activate.sh`) |
| `CS_PROCEVENT_CLAIM_ROOT` | cs-procevent | machine-wide process-event claim root; default `${XDG_STATE_HOME:-~/.local/state}/consigliere/procevent-claims` |
| `CS_PROCEVENT_MAX_OUTPUT_BYTES` | cs-procevent | cap on one captured result; default 1048576. Over the cap the result is truncated and still captured |
| `CS_LOCK_HARNESS_RE` | cs-session-pid-lib | test-only harness ancestry override, honored by every caller of that lib (the home lock and the telemetry breadcrumb key) |
| `CS_HARNESS_OVERRIDE` | cs-harness-lib | force the root harness (codex\|claude); highest precedence, test/escape seam |
| `CS_CLAUDE_JSON`, `CS_CODEX_TOML` | cs-harness-lib | test/escape seam pointing a harness's folder-trust store at a throwaway file instead of `~/.claude.json` / `~/.codex/config.toml`; `tests/lib.sh` defaults both for every suite that drives `cs-spawn.sh`, and the two live lifecycle suites clear them to exercise the real store (docs/codex.md) |
| `CS_TELEMETRY_DISABLE` | cs-telemetry-lib | test/escape seam, unset in production: `1` forces turn telemetry off whatever `host/telemetry.conf` says. `tests/lib.sh` pins it for every suite, because most suites resolve `DATA` to the real repo checkout and would otherwise append synthetic test turns to a developer's own dataset |
| `CS_ROOT_OVERRIDE` `CS_STATE_OVERRIDE` | single scripts | test-only resolution overrides |

Root harness resolution (`cs_harness_detect_root`): `CS_HARNESS_OVERRIDE` → `host/harness.conf` file → `CLAUDECODE=1` ⇒ claude → default codex. A soldier inherits the resolved value (persisted as `harness=` in meta).


Per-harness launch flags and hook facts: `docs/codex.md`, `docs/claude.md`.
Verified `lavish-axi` facts: `docs/lavish.md`.
Supervision protocol: `docs/supervision.md`.
Optional turn telemetry: `docs/telemetry.md`.
