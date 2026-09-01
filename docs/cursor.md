# Cursor Agent CLI verified facts

Verified live against cursor-agent 2026.08.31-4057e58 on 2026-09-01 at `~/.local/bin/cursor-agent` (legacy alias `agent` on PATH).
Re-verify after cursor-agent upgrades; `bin/cs-bootstrap.sh` checks presence only, not version.
Per-harness launch flags and hook facts live in `bin/cs-harness-lib.sh`; binary resolution, session sidecars, and workspace binding live in `bin/cs-cursor-lib.sh`.

## Binary and identity

```
$ cursor-agent --version
2026.08.31-4057e58
```

```
$ cursor-agent --help 2>&1 | head -3
Usage: agent [options] [command] [prompt...]

Start the Cursor Agent
```

- Primary binary: `cursor-agent` at `~/.local/bin/cursor-agent` (also symlinked as `~/.local/bin/agent`).
- The legacy name `agent` is far too generic to trust on basename alone; `bin/cs-cursor-lib.sh` accepts it only when it resolves into Cursor's install tree or its `--help` identifies the Cursor Agent CLI.
- Root-session detection: `CURSOR_AGENT=1` or `CURSOR_INVOKED_AS=cursor-agent`, checked after `host/harness.conf` and before `GROK_AGENT=1` / `CLAUDECODE=1` in `cs_harness_detect_root`, because cursor does not clear an inherited `CLAUDECODE`.
- Child/tool processes may export `CURSOR_*` variables; hook subprocesses stamp every payload with `cursor_version` (verified live 2026-09-01).

## Hook compatibility (primary checkout)

Cursor Agent CLI loads `<project>/.claude/settings.json` and `<project>/.codex/hooks.json` in addition to its own `<project>/.cursor/hooks.json` (verified live 2026-09-01).
A Cursor primary running in a consigliere checkout therefore fires both Claude-shaped and Codex-shaped registrations for every event Cursor's compatibility map covers.
Consigliere's `.cursor/hooks.json` owns those events; tracked Claude/Codex entries stand down on payloads carrying `cursor_version` through `bin/cs-hook-host-lib.sh` (wired in the hook scripts and in the tracked hook command wrappers).

Primary registrations:

- `sessionStart` -> `bin/cs-sessionstart-cursor.sh --source startup` (wraps `bin/cs-sessionstart-run.sh` as JSON `additional_context`).
- `stop` -> `bin/cs-turnend-guard-cursor.sh` (park model: foreground `bin/cs-watch-arm.sh`, follow-up on actionable wake or bounded repair nag).

Exit status 2 is a silent no-op on Cursor's `stop` step (verified live on 2026.08.11-e8db854; consigliere's cursor adapter never exits 2 and uses `{"followup_message": ...}` on stdout instead).

## Launch template (interactive soldier)

An interactive soldier or capo launches via herdr's native `agent start`, not a typed shell command:

`herdr agent start <id> --kind cursor --pane <p> --timeout <ms> -- [--trust --yolo] [--continue] [--workspace <abs-worktree>]`.

Exactly one autonomy pair is emitted: `--trust --yolo` (unattended full autonomy).
The brief is NOT part of this call; `bin/cs-spawn.sh` delivers it as a follow-up prompt via `cs_herdr_agent_prompt_confirmed`, same as codex and claude.

Launch env clears foreign harness markers before the agent starts: `env -u CLAUDECODE -u GROK_AGENT -u PI_CODING_AGENT -u CURSOR_INVOKED_AS`.

Turn-end is NOT wired inline for soldiers.
Cursor's turn lifecycle is pull-based: it writes durable per-conversation transcripts under `~/.cursor/projects/`.
`bin/cs-spawn.sh` writes `state/<id>.cursor-session` binding the projects root and workspace path so busy detection folds the correct conversation.
A cursor capo/primary instead runs the tracked project-scope `.cursor/hooks.json` in its own home; the stop-hook park owns that home's supervision.

## Headless scout

```
$ cursor-agent -p 'Reply with exactly: OK' --output-format text
```

- Headless mode uses `-p` / `--print` (alias documented in `--help`).
- Process exit IS the turn end; no Stop hook is armed for scouts.
- `--output-format` choices from `--help`: `text`, `json`, `stream-json`.

## Resume

From `--help`:

- `--continue` - Continue previous session (default: false).
- `--resume [chatId]` - Select a session to resume.

Consigliere's relaunch path uses `--continue` through `cs_harness_resume_argv`, cwd-keyed like claude and grok.

## Permission / trust

From `--help`:

- `--trust` - Trust the current workspace without prompting.
- `--yolo` - Alias for `--force` (Run Everything).
- `--workspace <path-or-name>` - Workspace directory or saved workspace name.

Interactive soldiers require `--trust` so project hooks load; consigliere pre-binds `--workspace` to the task worktree via `cs_harness_cursor_workspace_argv`.

## Interaction facts

- Skill invocation is `/<skill>` (slash form, same as claude and grok).
- Exit is `/exit`.
- Interrupt during a live turn is Escape (`cs_harness_interrupt_key` returns `esc`).
- Busy corroboration uses a mid-turn `ctrl+c to stop` banner (`cs_harness_busy_re`).
- Instruction file: `AGENTS.md`.
- Folder-trust prompt signature: `Do you trust the authors of the files in this folder?` (`cs_harness_trust_prompt_re`).

## Turn-end hook environment (primary)

Stop hook commands receive a Cursor-shaped JSON payload on stdin with at least:

- `session_id`, `generation_id`, `loop_count`, `status`, `hook_event_name`, `cursor_version`.

`loop_count` is 0 on the first stop after a real user message, increments on follow-up-driven stops, and resets on the next user message (verified live 2026.08.11-e8db854).
Consigliere's inner ceiling `CS_CURSOR_TURNEND_LOOP_CEILING` (default 180) sits below the registered `loop_limit` (200) so the session gets one loud notice before Cursor stops invoking the hook entirely.
