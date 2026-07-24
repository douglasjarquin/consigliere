# Claude Code verified facts

Verified live against claude 2.1.218 on 2026-07-24 (launch-scoped Stop hook fires
and blocks; `--settings` accepts a file or JSON string; no trust prompt under
`--dangerously-skip-permissions`).
Re-verify after claude upgrades; `bin/cs-bootstrap.sh` checks presence only, not
version. The launch template and per-harness facts live in `bin/cs-harness-lib.sh`.

## Launch template (the only one)

```
claude [--model <m>] [--effort <low|medium|high|xhigh|max>] \
  --dangerously-skip-permissions \
  --settings <state/<id>.claude-settings.json> \
  "$(bin/cs-operational-input.sh encode launch-brief < data/<id>/brief.md)"
```

- The typed `launch-brief` positional prompt starts the supervised interactive session.
- `--dangerously-skip-permissions` gives the unattended soldier full autonomy (no permission prompts).
- Turn-end is wired via the `--settings` Stop hook, NOT an inline flag: claude has
  no codex-style `-c notify=`. cs-spawn writes a per-soldier settings file whose
  `Stop` hook touches `state/<id>.turn-ended` every turn and then runs
  `bin/cs-turnend-guard.sh` (the continuation backstop).
- **Why a launch-scoped file, not `.claude/settings.json` in the worktree:** claude
  resolves a repo `.claude/settings.json` through worktrees to the MAIN checkout,
  so a file dropped in a soldier's worktree would land in the boss's real project
  tree and would not be soldier-isolated. `--settings <file>` scopes the hooks to
  the one launch. (`--settings` also accepts a raw JSON string; a file avoids
  shell-escaping the JSON inside the pane launch line.)
- Effort vocabulary: `low|medium|high|xhigh|max` (claude accepts `max`, unlike codex).
- A capo launch omits the turn-end wiring (a capo is a supervisor, not a supervised
  turn-taker) and prefixes `CS_HOME=<home>`.
- Headless scout: `claude -p "<brief>"` (process exit = turn end), the analog of `codex exec`.

## Hooks (.claude/settings.json)

- Root/capo primary session: `.claude/settings.json` at the repo root registers a
  self-verifying `Stop` hook that runs `bin/cs-turnend-guard.sh`. It fires only
  when the checkout's own `.claude/settings.json` still registers the guard, so a
  copied settings file cannot fire against a foreign tree (mirrors `.codex/hooks.json`).
- Stop payloads carry `stop_hook_active` (same loop-guard field codex uses); a Stop
  hook that exits 2 blocks the stop and forces one continuation.
- The blocked message is a TYPED `turn-end-guard` operational input, not raw text —
  claude scrutinizes hook stderr and will refuse a bare instruction as an injection,
  so the typed marker (honored per the loaded CLAUDE.md contract) is what makes it
  legitimate supervision.

## Interaction facts

- Skill invocation is `/<skill>` (claude's slash form; codex uses `$<skill>`).
  cs-send drives the prefix and the pre-Enter settle from the target's `harness=`
  meta: claude does not need codex's completion-popup settle.
- Session resume is cwd-keyed: `claude --continue` resumes the most recent session
  for the current worktree (the analog of `codex resume --last`). `--resume` opens a
  picker or takes a session id. Recovery never depends on capturing an id at spawn.
- Instruction file: claude loads `CLAUDE.md` (only), which is a symlink to `AGENTS.md`
  in every consigliere tree (`bin/cs-ensure-agents-md.sh` maintains the symlink), so
  codex and claude read the same operating contract.
- Root-session detection: a Claude Code session exports `CLAUDECODE=1`;
  `cs_harness_detect_root` reads it (after `config/harness` and `CS_HARNESS_OVERRIDE`).

## Known limitation

- Away-mode composer injection (`bin/cs-composer-lib.sh`) is tuned to codex's dim
  ghost-text rendering; it strips codex SGR de-emphasis before judging composer
  emptiness. A claude away-mode daemon session may need a claude-specific
  emptiness gate. The core loop (spawn, supervise, steer, land) is fully
  harness-parametrized; only this away-mode rendering detail remains codex-tuned.

## Native features deliberately available to consigliere

- `claude -p` / `--print` - headless non-interactive run; used for `--headless` scouts.
- `--output-format json|stream-json` - structured output, unused today.
- Herdr-native agent status (`agent_status`) auto-detects a claude agent the same as
  a codex agent, so busy/idle/done detection is harness-agnostic; the rendered-banner
  corroboration ("esc to interrupt") is shared.
