# Grok Build verified facts

Verified live against grok 1.0.5 (5115b46bc909) [stable] on 2026-09-01 at `~/.grok/bin/grok`.
Re-verify after grok upgrades; `bin/cs-bootstrap.sh` checks presence only, not version.
Per-harness launch flags and hook facts live in `bin/cs-harness-lib.sh`; binary resolution and turn-end wiring live in `bin/cs-grok-lib.sh`.

## Binary and identity

```
$ ~/.grok/bin/grok --version
grok 1.0.5 (5115b46bc909) [stable]
```

- Primary binary: `grok` at `~/.grok/bin/grok` (also symlinked as `~/.grok/bin/agent`).
- `GROK_HOME` selects the config/data root; default is `~/.grok`.
- `grok inspect` in this repo reports `Project trusted: yes` for a git worktree under a registered project root.
- Child/tool processes may export `GROK_AGENT=1` (fast path only); hook subprocesses export `GROK_HOOK_EVENT`, `GROK_HOOK_NAME`, `GROK_SESSION_ID`, and `GROK_WORKSPACE_ROOT` without necessarily setting `GROK_AGENT`.
- Herdr integration: `herdr integration status` reports `grok: current (v1)` at `~/.grok/hooks/herdr-agent-state.sh`.

## Launch template (interactive soldier)

An interactive soldier or capo launches via herdr's native `agent start`, not a typed shell command:

`herdr agent start <id> --kind grok --pane <p> --timeout <ms> -- [--always-approve | --permission-mode <mode>] [--continue]`.

Exactly one autonomy flag is emitted, never both.
The default unattended flag is `--always-approve`.
`config/permission-mode.conf` may select a narrower `--permission-mode` instead; accepted values are `default`, `auto`, `acceptEdits`, and `bypassPermissions`.

The brief is NOT part of this call.
`agent start`'s trailing argv cannot hold multi-line text; `bin/cs-spawn.sh` delivers the brief as a follow-up prompt via `cs_herdr_agent_prompt_confirmed`, same as codex and claude.

Turn-end is wired through a global Stop hook under `${GROK_HOME}/hooks/cs-turn-end.json`, NOT an inline launch flag.
Project hooks under `<worktree>/.grok/hooks/` require folder trust; global hooks under `~/.grok/hooks/` load without that gate.
Consigliere installs a guarded global hook that touches `state/<id>.turn-ended` only when the workspace holds a matching `.cs-grok-turnend` pointer and registry token (`bin/cs-grok-lib.sh`).

## Headless scout

```
$ grok -p 'Reply with exactly: OK' --output-format plain
```

- Headless mode uses `-p` / `--single <PROMPT>` (alias documented in `--help`).
- Process exit IS the turn end; no Stop hook is armed for scouts.
- `--output-format` choices (from `--help`, verified by rejection of invalid values):

```
error: invalid value 'text' for '--output-format <OUTPUT_FORMAT>'
  [possible values: plain, json, streaming-json, streaming-messages-json]
```

A live `-p` run against this machine returned HTTP 402 (usage balance exhausted) after accepting the flags; flag parsing succeeded before the API refusal.

## Resume

From `--help`:

- `-c`, `--continue` - Continue the most recent session for the current working directory.
- `-r`, `--resume [<SESSION_ID_OR_TITLE>]` - Resume by id/title, or most recent when omitted.

Consigliere's relaunch path uses `--continue` through `cs_harness_resume_argv`, same cwd-keyed semantics as claude.

## Permission modes

```
--permission-mode <MODE>
  [possible values: default, acceptEdits, auto, dontAsk, bypassPermissions, plan]
```

Unattended soldiers accept `default`, `auto`, `acceptEdits`, and `bypassPermissions` through `config/permission-mode.conf`.
`plan` and `dontAsk` are refused because they wedge the pane.

## Interaction facts

- Skill invocation is `/<skill>` (Claude-Code-compatible slash form).
- Slash autocomplete can consume the first Enter; `cs_harness_composer_command_settle grok` returns `1`.
- Exit is `/exit`.
- Interrupt during a live turn is Ctrl+C (`cs_harness_interrupt_key` returns `C-c` for herdr); Escape focuses scrollback instead of cancelling.
- Busy corroboration uses a mid-turn `Ctrl+c:cancel` banner (`cs_harness_busy_re`).
- Instruction file: `AGENTS.md` (grok `inspect` lists project `Agents.md`, which resolves to the same contract in consigliere trees).
- Root-session detection: `GROK_AGENT=1` after `host/harness.conf` and before `CLAUDECODE=1` in `cs_harness_detect_root`.

## Turn-end hook environment

Stop hook commands receive the standard Claude-Code-compatible hook payload on stdin.
Consigliere's global hook reads `GROK_WORKSPACE_ROOT` to locate the workspace-local `.cs-grok-turnend` pointer; the pointer carries `token=cs.<id>` and the registry under `~/.grok/hooks/cs-turn-end.d/` maps that token to the absolute `state/<id>.turn-ended` path without exposing it in the worktree file.
