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
Prose and records use `.md`; settings use `.conf`; the extension marks the format, never the tier - `config/` holds four genuinely portable `.conf` files, and every other `.conf` file is machine-local and lives in `host/`.
`bin/cs-migrate-config.sh` owns the one-shot move from the pre-2026-08 layout, and the fail-closed gate in `bin/cs-root-lib.sh` refuses every script while any old-name path exists.

| file | tier | semantics |
|---|---|---|
| `config/boss.md` | portable | boss preferences and working style; inspect-then-update |
| `config/boss-shared.md` | portable | main-authoritative shared boss preferences; source of the capo propagation |
| `config/learnings.md` | portable | curated fleet-local operational facts |
| `config/projects.md` | portable | fleet navigation registry with standing per-project posture |
| `config/boards.md` | portable | per-project GitHub Projects board mapping (schema below) |
| `config/backlog.md` | portable | the durable queue; written by tasks-axi (`.tasks.toml` owns schema) |
| `config/done-archive.md` | portable | tasks-axi done archive, pinned by `.tasks.toml` |
| `config/note-archive.md` | portable | tasks-axi body archive; an internal sibling name tasks-axi creates beside the backlog |
| `config/charter.md` | portable, capo homes only | the capo's filled charter brief |
| `config/backlog-backend.conf` | portable | absent or `tasks-axi` = tasks-axi against `config/backlog.md`; `manual` = hand-edit the markdown |
| `config/dispatch-policy.conf` | portable | optional per-home profiles for task dispatch; `bin/cs-spawn.sh` owns its strict four-column schema below |
| `config/permission-mode.conf` | portable | optional narrower claude launch permission mode; absent = full autonomy; `bin/cs-harness-lib.sh` owns the two-column schema below. This is a Claude ACCOUNT policy, not a machine property - the record is `<harness> <mode>` with no machine-specific content, so the same file is correct verbatim on every machine that account uses; do not re-derive it as host-specific |
| `config/wedge-alarm.conf` | portable | away-mode wedge-alarm active-alert directives; absent = auto (macOS Notification Center when available, degrading elsewhere). A boss preference, boss-authored only; the directives are channel selectors that adapt per OS, so the file is portable. The one non-portable use is a `command:` directive naming a machine-local path - keep such a value out of shared dotfiles |
| `host/capos.md` | host | capo routing table; every record embeds an absolute machine-local home path |
| `host/harness.conf` | host | pins the root harness (`codex` or `claude`) regardless of environment |
| `host/upstream.conf` | host | path of the firstmate checkout for `/upstream-review`; absent = `../firstmate` |
| `host/activation.conf` | host | per-home activation scope: `always`, `afk-only`, or `off`; absent = `afk-only`; `bin/cs-activate.sh` owns the policy, and `bin/cs-home-seed.sh --help` owns capo seed and bootstrap convergence |
| `host/telemetry.conf` | host | optional per-home turn telemetry switch: `enabled true\|false` plus an optional `retain_days <1..3650>`; absent = disabled, malformed = disabled with a doctor diagnostic. `docs/telemetry.md` owns the whole contract. Never propagated into a capo home, which enables its own |

Symlink policy, established empirically (2026-08-06, tasks-axi 0.2.x):

- `boss.md`, `boss-shared.md`, `learnings.md`, `projects.md`, `boards.md`, and the four portable `.conf` files are read-only to scripts and safe to symlink out to a dotfiles repository.
- `backlog.md`, `done-archive.md`, `note-archive.md`, and `host/capos.md` are rewritten by rename (tasks-axi and the registry writers), which replaces a symlink with a regular file and silently forks the content; they must be real files, and the doctor fails when one is a symlink.
- A `host/` entry whose symlink target resolves outside the home defeats the host tier (the `capos.md`-across-two-machines mistake); the doctor fails on it.

Inheritance into capo homes: `config/boss-shared.md` is propagated read-only, and `config/backlog-backend.conf` is copied at seed time; nothing else is inherited, and nothing in `host/` ever propagates.
Capo activation is local rather than inherited; see `bin/cs-home-seed.sh --help` for its seed and bootstrap convergence contract.
The main-side source of either may be a symlink that resolves to a regular file, because propagation only reads it; an unresolved symlink stops propagation instead of mirroring absence.
The capo-side destination must be a plain regular file, because propagation writes there and following a link out of the capo home is exactly what that check prevents.
`bin/cs-inherit-lib.sh` owns the allowlist.

### Dispatch policy

`config/dispatch-policy.conf` is optional and local to one Consigliere home.
It sets default model and effort values for the resolved harness and task kind.
The path may be a regular file or a symlink that resolves to one, so a home may keep its policy under external configuration management.
A symlink that does not resolve stops dispatch, because silently ignoring a broken policy is indistinguishable from having none.
One non-comment line has exactly four whitespace-separated fields:

```text
<harness> <kind> <model> <effort>
```

`harness` is `codex` or `claude`.
`kind` is `scout` for planning, investigations, and audits, `ship` for implementation, or `capo` for a persistent dispatcher.
`model` is `default` or an identifier containing letters, numbers, `.`, `_`, `:`, and `-`.
`effort` is `default`, `low`, `medium`, `high`, `xhigh`, or `max` for either harness, with `ultra` additionally supported by Codex.
Blank lines and lines whose first field begins with `#` are ignored.
Every record is validated and duplicate `<harness> <kind>` entries stop dispatch with an error.

```text
# harness kind  model          effort
codex scout     gpt-5.6-sol    xhigh
codex ship      gpt-5.6-terra  high
claude scout    opus           xhigh
claude ship     sonnet         high
```

An explicit `cs-spawn.sh --model` or `--effort` value overrides only that policy axis for that task.
An absent policy or absent matching line retains the existing harness default.

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
- `state/<id>.meta` - written by `cs-spawn.sh`: `workspace=`, `pane=`, `worktree=`, `project=`, `model=`, `effort=`, `kind=` (ship|scout|capo), `harness=` (codex|claude, inherited from the root session).
  A `kind=ship` task also records the posture its spawn stated explicitly: `mode=` (no-mistakes|direct-PR|local-only) and `yolo=` (on|off).
  A `kind=scout` records NEITHER, because a report deliverable has no mode to honour and no approval posture to apply, which is why `cs-promote.sh` is where a promoted scout first states both.
  `kind=capo` records `mode=capo`, `yolo=off`, and `home=`.
  `cs-spawn.sh` also records `issue=` for board-driven work and `headless=1` for a headless scout (`codex exec` / `claude -p`); `cs-pr-check.sh` appends `pr=` and any available `pr_head=`.
- `state/<id>.status` - appended by soldiers; wake events, never current state. `bin/cs-classify-lib.sh` owns the verb vocabulary.
- `state/.decision-cursor-<task>` - per-status-file byte cursor plus folded open-decision set, written only by `bin/cs-classify-lib.sh`'s `status_open_decisions_incremental` so the wake drain's fleet-wide open-decision scan folds only newly appended status bytes. Removed by teardown with the other watcher markers, along with any `.read.*` / `.tmp.*` staging temps a killed drain left beside it; always safe to delete by hand, which only costs one full re-fold of that task's status log.
  If `state/` is unwritable so no cursor can be staged at all, the drain falls back to the unbounded whole-file fold for that call rather than reporting nothing open.
- `data/telemetry/turns.jsonl` - append-only JSON Lines turn telemetry for this home, written only while `host/telemetry.conf` enables it, with `state/.telemetry-crumbs-<pid>-<hash>` (turn-scoped breadcrumbs, keyed to the harness process and its reuse-proof identity, discarded once older than `CS_BUSY_TURN_MAX_SECS`) and `state/.telemetry-cursor-<session>` (per-harness-session transcript byte offset plus the effort and model that session last stated) as its disposable working state. `docs/telemetry.md` owns the schema, the folding rules, retention, and the privacy contract; `bin/cs-telemetry-lib.sh` implements them.
- `state/.wake-queue` - `epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload`; `bin/cs-wake-lib.sh` owns it.
- `state/.session-start-complete` - the lock owner's pid, written atomically by `bin/cs-session-start.sh` only when a full locked startup reached its final stage, and cleared when the next full locked startup begins. `bin/cs-sessionstart-run.sh` re-emits on a clear or compact only when this record matches the current lock owner in its own ancestry, so a startup killed mid-sweep is finished before any re-emit. Safe to delete by hand, which only costs one full startup on the next clear or compact.
- `state/.startup-network.*` - the deferred network stage's own records, owned by `bin/cs-startup-network.sh` (its header owns the exact fields).
  `.status` is the key=value source of truth for what ran and how it ended, `.report` is the current result - a `covered=<phases>` line naming the checks that run speaks for, then the sweep output byte for byte as `bin/cs-bootstrap.sh` produced it - `.claim` names the session start that intends to print it inline, `.delivered` is the one durable acknowledgement that suppresses its wake - written only by a reader that actually printed the result, and cleared only by a publish that actually replaced it - and `.lock` serializes publication, acknowledgement, and the wake decision.
  `.timings` is where that stage spent its time - one elapsed-time record per check owner and per item inside it, all offset from one shared origin, in `bin/cs-timing-lib.sh`'s format - published by the same publish for every outcome, including a run that timed out or failed, where the partial record names the step that never finished; only `cs-startup-network.sh report` prints it, so the digest is unaffected.
  `.pending/` holds whole results that finished and were never read, one per file in the same format and named so plain name order is oldest first; results are never merged, so a publish that would land on an unread result moves it here first.
  A harvest prints that store ahead of the current result and empties it, and the store keeps only its most recent few results, disclosing by number any older ones it dropped.
  Safe to delete by hand between sessions: the sweeps are idempotent detectors, so the next session start re-derives every finding.
- `state/.home-pane` - the pane id of THIS home's own agent, written by `bin/cs-session-start.sh` from `HERDR_PANE_ID` (the one place that runs inside the home's own pane). A durable HINT, never an identity: herdr recycles pane ids, so `bin/cs-activate.sh` revalidates that the pane still exists, still runs an agent, and is still rooted in this home before it will prompt anything.
- `state/.last-activation` - cooldown stamp for `bin/cs-activate.sh`; also the recursion guard, since the turn activation starts drains the queue and may append more wakes.
- `state/.activation-stalled` - durable marker that this home cannot self-activate (pane gone, pane recycled to another home, or no agent). Its whole purpose is that a home with the parent removed from the loop fails loudly instead of rotting.
- `state/procevent/` and `state/procevent-inbox/` - armed blocking sources and their captured results; see `## Process events` below.
- `state/.subsuper-daemon-beat` - the away daemon's proof that it is supervising, written by `bin/cs-daemon.sh` at the BOTTOM of each loop pass, so the early-continue paths (pane gone, watcher crash backoff) deliberately do not write it. Contents are a strictly increasing pass counter; mtime is its freshness. `bin/cs-afk-verify.sh` requires the counter to ADVANCE before away mode is armed; `bin/cs-monitor.sh` requires it fresh before standing down. A live pid is not proof: it survives a recycled pid and a daemon wedged off its loop.

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
| `CS_STALE_ESCALATE_SECS` | cs-watch, cs-daemon | wedge escalation threshold |
| `CS_BUSY_TURN_MAX_SECS` | cs-watch | how long a pane may run busy with no completed turn before it enters the wedge timer; default 3600 |
| `CS_SESSION_START_TIMEOUT` | cs-session-start | hard bound in seconds for the whole digest, which runs as one bounded child because the session-open hooks block session initialization while it runs; on expiry the parent prints the STARTUP TRUNCATED banner naming the stalled stage and every stage that never ran, and still exits 0. A host where the bound cannot be established at all (an unusable `TMPDIR`) gets the separate STARTUP DID NOT RUN banner instead, because a digest that never started is not a digest that stalled. Default 120 |
| `CS_TIMEOUT_MECHANISM_OVERRIDE` | cs-timeout-lib | set to `bash` to force the dependency-free watchdog fallback; tests use it to exercise the bound on hosts that ship timeout/gtimeout/perl |
| `CS_BOOTSTRAP_LOCKED` | cs-bootstrap | set alongside `CS_BOOTSTRAP_DETECT_ONLY=1` when the sweeps are skipped because THIS session already ran them while holding the lock (a `--reemit`), so tangle repair ownership stays with this session instead of deferring to a lock holder that is itself |
| `CS_BOOTSTRAP_NETWORK` | cs-bootstrap | `all` (default, and any unrecognized value), `skip` (every local step, no network one), or `only` (every network step and nothing else). The two halves are a strict partition of the unsplit run; `bin/cs-session-start.sh` passes `skip` and `bin/cs-startup-network.sh` runs `only` |
| `CS_BOOTSTRAP_NETWORK_LOCK_PID` | cs-bootstrap | the `state/.lock` owner a deferred worker captured while that session still held the lock; each network mutating sweep re-verifies it and reports a skip rather than sweeping on behalf of a session that has gone away |
| `CS_STARTUP_NETWORK_TIMEOUT` | cs-startup-network | one aggregate hard bound in seconds for the whole deferred network stage, which runs outside `CS_SESSION_START_TIMEOUT` in its own process group. Hitting it is reported as a `NETWORK_CHECKS:` line, never as silence. Default 120 |
| `CS_STARTUP_MEMORY_MAX_BYTES` | cs-session-start | per-file budget for `config/boss.md`, `config/boss-shared.md`, and `config/learnings.md`; over budget is reported in the digest, never truncated. Default 8192 |
| `CS_SESSION_START_STATUS_TAIL` | cs-session-start | `state/*.status` lines printed per task in the session-start digest; default 5; each line is capped by `bin/cs-line-cap-lib.sh` |
| `CS_SESSION_START_QUEUED_LIMIT` | cs-session-start | plain queued backlog rows in the session-start digest; default 20; done rows are never listed |
| `CS_SESSION_START_ACTIVE_LIMIT` | cs-session-start | in-flight, held, and blocked backlog rows per group in the session-start digest; default 40; each row is shown in full and any remainder is disclosed with the targeted follow-up that prints the rest; queued public-followup rows are outside this bound and always print in full |
| `CS_PAUSE_RESURFACE_SECS` | cs-watch, cs-daemon | declared external-wait recheck cadence |
| `CS_BOARD_SWEEP_LANES` | cs-board-watch | default lane cap baked into a new sweep record; default 3, matching the `contracts` skill |
| `CS_BOARD_SWEEP_RESURFACE` | cs-board-watch | default seconds before a still-full column is reported again; default 1800. Only a default for `arm`; each record stores its own value |
| `CS_MAX_DEFER_SECS` | cs-daemon | away-mode escalation max-defer alarm |
| `CS_AFK_BEAT_STALE` | cs-monitor | seconds before the away daemon's completed-pass counter reads stale and the monitor covers the home instead of standing down; default 180, deliberately above the daemon's own 60s crash backoff |
| `CS_SPAWN_LAUNCH_WAIT_SECS` | cs-spawn | seconds to wait for an agent to actually appear after the launch line is delivered, before treating the launch as swallowed; default 60 |
| `CS_ACTIVATE_QUIET_SECS` | cs-activate | the wake queue must have been still this long before activating, so one burst of wakes produces one turn; default 60 |
| `CS_ACTIVATE_COOLDOWN_SECS` | cs-activate | minimum seconds between activations in a home; also the recursion guard; default 600 |
| `CS_PROMPT_CONFIRM_WAIT_MS` | cs-prompt-lib | ms to wait for the idle->working transition that proves a prompt was delivered; default 8000 |
| `CS_AFK_VERIFY_TICKS` | cs-afk-verify | 0.1s ticks to wait for the counter to advance before rolling away mode back; default 150 |
| `CS_PROCEVENT_CLAIM_ROOT` | cs-procevent | machine-wide process-event claim root; default `${XDG_STATE_HOME:-~/.local/state}/consigliere/procevent-claims` |
| `CS_PROCEVENT_MAX_OUTPUT_BYTES` | cs-procevent | cap on one captured result; default 1048576. Over the cap the result is truncated and still captured |
| `CS_LOCK_HARNESS_RE` | cs-session-pid-lib | test-only harness ancestry override, honored by every caller of that lib (the home lock and the telemetry breadcrumb key) |
| `CS_HARNESS_OVERRIDE` | cs-harness-lib | force the root harness (codex\|claude); highest precedence, test/escape seam |
| `CS_TELEMETRY_DISABLE` | cs-telemetry-lib | test/escape seam, unset in production: `1` forces turn telemetry off whatever `host/telemetry.conf` says. `tests/lib.sh` pins it for every suite, because most suites resolve `DATA` to the real repo checkout and would otherwise append synthetic test turns to a developer's own dataset |
| `CS_ROOT_OVERRIDE` `CS_STATE_OVERRIDE` | single scripts | test-only resolution overrides |

Root harness resolution (`cs_harness_detect_root`): `CS_HARNESS_OVERRIDE` → `host/harness.conf` file → `CLAUDECODE=1` ⇒ claude → default codex. A soldier inherits the resolved value (persisted as `harness=` in meta).


Per-harness launch flags and hook facts: `docs/codex.md`, `docs/claude.md`.
Verified `lavish-axi` facts: `docs/lavish.md`.
Supervision protocol: `docs/supervision.md`.
Optional turn telemetry: `docs/telemetry.md`.
