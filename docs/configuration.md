# Configuration

Single owner of the operational-home layout and configuration schemas.
Each producing script's header and help own exact child fields and mutation mechanics.

## Homes

`CS_HOME` selects an instance's private `data/`, `state/`, `config/`, and `projects/`.
Scripts always come from their tracked code root (`CS_ROOT`, the repo checkout).
The main home is the repo checkout itself; each capo has a persistent isolated `CS_HOME` under `${CS_CAPOS_ROOT:-~/.consigliere/capos}/<id>` - a plain detached git worktree of this repo, never a herdr-managed worktree (a capo home must survive server restarts and empty workspaces).

Test and script overrides: `CS_ROOT_OVERRIDE`, `CS_STATE_OVERRIDE` narrow a single script's resolution; production flows never set them.

## Herdr layout

- One herdr session: `default` (labs excepted; see `bin/cs-herdr-lab.sh`).
- One home workspace per home: label `consigliere` for the main home, `capo-<id>` for capo homes.
- One workspace per task, created by `herdr worktree create` and labeled with the task id; the root pane is the task pane.
- `CS_HERDR_SESSION` overrides the session for lab work only.
- Verified herdr behavior and gaps: `docs/herdr.md`.

## config/ files (all LOCAL, gitignored)

| file | semantics |
|---|---|
| `config/backlog-backend` | absent or `tasks-axi` = tasks-axi against `data/backlog.md` (`.tasks.toml` owns schema); `manual` = hand-edit the markdown |
| `config/dispatch-policy` | optional per-home profiles for task dispatch; `bin/cs-spawn.sh` owns its strict four-column schema below |
| `config/permission-mode` | optional narrower claude launch permission mode for homes whose org policy forbids full bypass; absent = full autonomy; `bin/cs-harness-lib.sh` owns the two-column schema below |
| `config/upstream` | path or URL of the firstmate checkout for `/upstream-review`; absent = `../firstmate` |
| `config/wedge-alarm` | away-mode wedge-alarm active-alert directives; absent = auto (macOS Notification Center when available) |

Inheritance into capo homes: `data/boss-shared.md` is propagated read-only, and `config/backlog-backend` is copied at seed time; nothing else is inherited.
`bin/cs-inherit-lib.sh` owns the allowlist.

### Dispatch policy

`config/dispatch-policy` is optional and local to one Consigliere home.
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

`config/permission-mode` is optional and local to one Consigliere home.
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
`config/permission-mode` itself is not seeded into a capo home; set it there too if that capo spawns its own soldiers.

Operational consequence: under `auto` or `acceptEdits` a soldier can still stop on a permission prompt.
That pane looks busy rather than failed, so it surfaces through the ordinary stale-liveness path in `docs/supervision.md` instead of as an immediate failure.

## data/ and state/

The complete field-level inventory lives in AGENTS.md section 2; producing scripts own mutation:

- `data/boards.md` - per-project GitHub Projects (v2) board mapping for the `contracts` and `casino` skills, kept beside `data/projects.md` and keyed by the same project name. Blank lines and `#` comments ignored; every other line is `<project> <owner> <number> [ready-label] [in-progress-label] [status-field] [inbox-label] [backlog-label]`. Labels/field default to `Ready` / `In Progress` / `Status` / `Inbox` / `Backlog`; use `_` for spaces in a label token. `<owner>` is a user/org login or `@me`. `bin/cs-board.sh` reads it; the board mapping is optional (only projects worked via the board need a line), and the Inbox/Backlog columns matter only to `casino`.
- `state/<id>.meta` - written by `cs-spawn.sh`: `workspace=`, `pane=`, `worktree=`, `project=`, `model=`, `effort=`, `kind=` (ship|scout|capo), `mode=` (no-mistakes|direct-PR|local-only), `yolo=`, `harness=` (codex|claude, inherited from the root session); `kind=capo` also records `home=`; `cs-spawn.sh` also records `issue=` for board-driven work and `headless=1` for a headless scout (`codex exec` / `claude -p`); `cs-pr-check.sh` appends `pr=` and `pr_head=`.
- `state/<id>.status` - appended by soldiers; wake events, never current state. `bin/cs-classify-lib.sh` owns the verb vocabulary.
- `state/.wake-queue` - `epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload`; `bin/cs-wake-lib.sh` owns it.

## Environment variables

| variable | consumer | semantics |
|---|---|---|
| `CS_HOME` | all scripts | home selector; defaults to the repo root |
| `CS_HERDR_SESSION` | cs-herdr-lib | herdr session; labs only, defaults to `default` |
| `CS_CAPOS_ROOT` | cs-home-seed | capo home pool root; default `~/.consigliere/capos` |
| `CS_WATCH_CHECKPOINT` | cs-watch-checkpoint | bounded foreground checkpoint seconds; default 180 |
| `CS_CHECK_TIMEOUT` | cs-watch | per-check timeout for registered `state/<id>.check.sh` |
| `CS_STALE_ESCALATE_SECS` | cs-watch, cs-daemon | wedge escalation threshold |
| `CS_PAUSE_RESURFACE_SECS` | cs-watch, cs-daemon | declared external-wait recheck cadence |
| `CS_MAX_DEFER_SECS` | cs-daemon | away-mode escalation max-defer alarm |
| `CS_LOCK_HARNESS_RE` | cs-lock | test-only harness ancestry override |
| `CS_HARNESS_OVERRIDE` | cs-harness-lib | force the root harness (codex\|claude); highest precedence, test/escape seam |
| `CS_ROOT_OVERRIDE` `CS_STATE_OVERRIDE` | single scripts | test-only resolution overrides |

Root harness resolution (`cs_harness_detect_root`): `CS_HARNESS_OVERRIDE` → `config/harness` file → `CLAUDECODE=1` ⇒ claude → default codex. A soldier inherits the resolved value (persisted as `harness=` in meta).

- `config/harness` - optional; a single line `codex` or `claude` pins the root harness regardless of environment.

Per-harness launch flags and hook facts: `docs/codex.md`, `docs/claude.md`.
Supervision protocol: `docs/supervision.md`.
