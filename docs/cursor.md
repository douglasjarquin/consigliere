# Cursor Agent CLI verified facts

Verified live against cursor-agent at `~/.local/bin/cursor-agent` on 2026-09-01
(`--help` lists `--trust`, `--yolo`, `--workspace`, `--continue`, `-p/--print`;
herdr accepts `--kind cursor` for native `agent start`).
Re-verify after cursor-agent upgrades; `bin/cs-bootstrap.sh` checks presence only.
Per-harness launch facts live in `bin/cs-harness-lib.sh`; primary supervision in
`.cursor/hooks.json` and `bin/cs-turnend-guard-cursor.sh`.

## Launch template (soldiers and capos)

Interactive soldiers launch via herdr native `agent start`:

`herdr agent start <id> --kind cursor --pane <p> --timeout <ms> -- --trust --yolo --workspace <abs-worktree>`

- `--trust --yolo` are cursor-agent's unattended autonomy flags (analogous to
  codex bypass and claude skip-permissions).
- `--workspace <abs-dir>` binds the agent to the isolated task worktree. Never
  pass `-w` / `--worktree`: cursor allocates a second worktree under
  `~/.cursor/worktrees` and breaks consigliere isolation.
- Resume uses `--continue` on the same workspace path.
- The brief is NOT part of `agent start` (multi-line argv is refused); `bin/cs-spawn.sh`
  delivers it as a follow-up prompt after `interactive_ready`, same as claude/codex.
- Before launch, `bin/cs-spawn.sh` exports `env -u CLAUDECODE -u GROK_AGENT -u PI_CODING_AGENT -u CURSOR_INVOKED_AS`
  into the pane because cursor does not clear inherited foreign harness markers.
- `bin/cs-spawn.sh` writes `state/<id>.cursor-session` (projects root + workspace
  path) so busy detection can fold cursor's durable JSONL transcript per turn.
- No per-soldier turn-end hook: cursor soldiers rely on herdr status + transcript
  fold, not a Stop/settings/notify wiring.

Headless scouts use `cursor-agent -p --trust --yolo --workspace <abs-worktree>`
via `pane run`; process exit is the turn end.

## Primary session (consigliere root or capo home)

Tracked `.cursor/hooks.json` registers:

- `sessionStart` -> `bin/cs-sessionstart-cursor.sh --source startup` (RUN tier:
  injects `bin/cs-session-start.sh` digest as `additional_context` JSON).
- `stop` -> `bin/cs-turnend-guard-cursor.sh` (park model: foreground
  `bin/cs-watch-arm.sh` until an actionable wake, then emit at most one
  `{"followup_message":...}` on stdout).

Cursor `stop` exit 2 is a silent no-op (verified live 2026.08.11-e8db854): the
adapter never blocks with exit 2; repair uses bounded follow-ups instead.

Because cursor also loads `.claude/settings.json` and `.codex/hooks.json` from the
same checkout, tracked Claude/Codex hook entrypoints stand down when the payload
carries `cursor_version` (`bin/cs-hook-host-lib.sh`).

Detection: `host/harness.conf` wins over env markers when present; otherwise
`CURSOR_AGENT=1` or `CURSOR_INVOKED_AS=cursor-agent` outrank inherited
`CLAUDECODE=1`; ancestry walk uses `bin/cs-cursor-lib.sh` for node/cursor-agent
process shapes (`bin/cs-harness-lib.sh` `cs_harness_detect_root`).

## Composer and control

- Prompt glyph: `→` (U+2192), recognized by `bin/cs-composer-lib.sh`.
- Busy footer corroboration: `ctrl+c to stop` (`cs_harness_busy_re`).
- Composer command settle: 1 (slash popup swallows Enter, like codex).
- Interrupt: Escape (`cs_harness_interrupt_key`).
- Exit command: `/exit` (`cs_harness_exit_command`).
- Instruction file: `AGENTS.md` (`cs_harness_instruction_file`).

## Supervision model

Between turns, cursor primary supervision parks in the stop hook (autoarm model):
`bin/cs-watch-arm.sh` runs one blocking `bin/cs-watch.sh` cycle as a tracked
child of the hook. Persistent `bin/cs-monitor.sh` still keeps the home watched
while the agent works inside a turn; the park covers turn boundaries only.

Loop bounding is double: `.cursor/hooks.json` `loop_limit` (200) and
`CS_CURSOR_TURNEND_LOOP_CEILING` (default 180) inside the adapter.
