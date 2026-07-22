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
| `config/upstream` | path or URL of the firstmate checkout for `/upstream-review`; absent = `../firstmate` |
| `config/wedge-alarm` | away-mode wedge-alarm active-alert directives; absent = auto (macOS Notification Center when available) |

Inheritance into capo homes: `data/boss-shared.md` is propagated read-only, and `config/backlog-backend` is copied at seed time; nothing else is inherited.
`bin/cs-inherit-lib.sh` owns the allowlist.

## data/ and state/

The complete field-level inventory lives in AGENTS.md section 2; producing scripts own mutation:

- `state/<id>.meta` - written by `cs-spawn.sh`: `workspace=`, `pane=`, `worktree=`, `project=`, `model=`, `effort=`, `kind=` (ship|scout|capo), `mode=` (no-mistakes|direct-PR|local-only), `yolo=`; `kind=capo` also records `home=`; `cs-pr-check.sh` appends `pr=` and `pr_head=`; `cs-spawn.sh` appends `codex_session=` when it can capture one.
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
| `CS_ROOT_OVERRIDE` `CS_STATE_OVERRIDE` | single scripts | test-only resolution overrides |

Codex launch flags and hook facts: `docs/codex.md`.
Supervision protocol: `docs/supervision.md`.
