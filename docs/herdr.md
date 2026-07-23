# Herdr verified facts

Verified against herdr 0.7.4 (protocol 16) on 2026-07-22 in an isolated lab session.
Re-verify this table after any herdr upgrade; `bin/cs-bootstrap.sh` gates on the minimum protocol.

## Session discipline

- Every CLI call carries an explicit trailing `--session <name>`; ambient `HERDR_SESSION` alone is not trusted (upstream firstmate evidence: unreliable once another server runs).
- The live session is `default`; tests and consigliere-on-itself lifecycle tasks use `bin/cs-herdr-lab.sh` labs named `cs-lab-*`, never `default`.
- Headless lab provisioning: `HERDR_SESSION=<name> herdr server --session <name> &`, socket at `~/.config/herdr/sessions/<name>/herdr.sock`.
- CLI subcommands emit JSON by default; there is no `--json` flag on `workspace`/`worktree` subcommands (only some, e.g. `status`, `session list`).

## Container shape: workspace-per-task

`herdr worktree create --workspace <src> --branch <name> --label <task-id> --no-focus` verified behavior:

- Creates the worktree at `~/.herdr/worktrees/<repo_name>/<branch-sanitized>` (branch `cs/t1` -> dir `cs-t1`).
- `--branch` and `--base REF` control branch creation; the branch is real and persists.
- Creates a NEW workspace bound to the worktree (the `--workspace` argument only names the source workspace whose repo is used); the response carries `workspace_id`, `tab_id`, `pane_id`, `worktree.path`, `worktree.branch`.
- The root pane IS the task pane; no seeded default tab to prune in the worktree flow.
  (The prune concern applies only to bare `workspace create`, which seeds a default tab labeled "1".)

So consigliere's shape is: one home workspace (`consigliere`, or `capo-<id>`) where the supervisor runs, plus one workspace per task, created by `worktree create` and labeled with the task id.

## Worktree lifecycle safety (D1 verification)

- `worktree remove --workspace <id>` on a dirty worktree fails closed: `dirty_worktree_requires_force`. `--force` is the only override.
- Clean `worktree remove` deletes the worktree directory, closes the workspace, and PRESERVES the branch (safe for PR flows).
- `workspace close <id>` does NOT delete the worktree; dirty work survives.
- Server stop/restart: workspaces are restored; a worktree whose workspace is gone is recovered with `worktree open --path <path> --label <label>` (`already_open:false` on success; binds a fresh workspace).
- `worktree list --cwd <path>` lists all worktrees of the repo with `branch`, `path`, `open_workspace_id`.
- cs-teardown still owns the landed-work proofs; `herdr worktree remove` runs only after those proofs pass and is never itself the safety mechanism.

## Native agent status (verified against live codex)

- `agent list` / `agent get <pane>` detect codex automatically (`"agent":"codex"`) with `agent_status`: `idle|working|blocked|done|unknown`.
- Mid-turn status reads `working`; after the turn ends it reads `idle`.
- `agent wait <pane> --status idle --timeout <ms>` blocks until the status is reached (verified ~5s wait resolving on turn end); use it for submit confirmation and bounded single-target waits.
- Known upstream gap (firstmate evidence, docs/herdr-backend.md): `agent get` can read `idle` during a LONG foreground tool call. Policy: native `working` is trusted outright; native `idle`/`unknown` must be corroborated against the codex busy signature (`esc to interrupt`) before a soldier is declared not-working. Single constant in `cs-herdr-lib.sh`.

## Capture

- `pane read <pane> --lines N --format text|ansi` returned exactly N lines on 0.7.4; the upstream small-`--lines` truncation bug was NOT reproduced. `cs-herdr-lib.sh` passes `--lines` through directly; if a regression appears, re-add the read-wide-then-tail workaround from firstmate's adapter.
- `pane run <pane> '<text>'` submits text plus Enter atomically (verified launching codex and steering it).
- Machine input uses U+2063 INVISIBLE SEPARATOR because it survives UTF-8 terminal input; the upstream herdr 0.7.3 incident showed ASCII 0x1f was stripped from the composer. `bin/cs-operational-input.sh` owns the exact bytes.

## Push events

- Multi-pane push (`events.subscribe` -> `pane.agent_status_changed`) is socket-only; no CLI subcommand.
- `bin/cs-herdr-events.py` is the raw AF_UNIX subscriber (ported from firstmate's herdr-eventwait.py); the watcher splices it in when the socket is capable and keeps the poll loop as the permanent backstop.

## Known gaps / watch list

- `worktree create` fails (`worktree_create_failed`) when the target directory `~/.herdr/worktrees/<repo_name>/<branch-sanitized>` already exists - e.g. leftovers from an aborted task whose repo clone is gone. cs-spawn must treat that as stop-and-report (a leftover directory may hold unlanded work); never pre-delete the path to make the create succeed.

- No `workspace move` CLI (method exists in `api schema`); consigliere does not order workspaces, so no shim is ported.
- Tab labels are not unique; list-live matching stays defensive (scope to this home's workspace ids from meta, never by label sweep).
- `herdr integration install codex` exists; not used yet — codex is launched directly with explicit flags so the launch template stays under consigliere's control.
