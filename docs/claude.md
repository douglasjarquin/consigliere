# Claude Code verified facts

Verified live against claude 2.1.218 on 2026-07-24 (launch-scoped Stop hook fires
and blocks; `--settings` accepts a file or JSON string; no trust prompt under
`--dangerously-skip-permissions`), and against claude 2.1.220 on 2026-07-28
(`--permission-mode auto` keeps the launch-scoped Stop hook firing).
Re-verify after claude upgrades; `bin/cs-bootstrap.sh` checks presence only, not
version. The launch template and per-harness facts live in `bin/cs-harness-lib.sh`.

## Launch template (the only one)

```
claude [--model <m>] [--effort <low|medium|high|xhigh|max>] \
  <--dangerously-skip-permissions | --permission-mode <mode>> \
  --settings <state/<id>.claude-settings.json> \
  "$(bin/cs-operational-input.sh encode launch-brief < data/<id>/brief.md)"
```

- The typed `launch-brief` positional prompt starts the supervised interactive session.
- `--dangerously-skip-permissions` gives the unattended soldier full autonomy (no permission prompts).
- `--permission-mode <auto|acceptEdits|bypassPermissions>` is the alternative for a home
  whose Claude account policy forbids the bypass flag; `config/permission-mode` selects it
  and `docs/configuration.md` owns that schema. It is the flag form of the interactive
  Shift+Tab mode cycle, so a pane starts in the chosen mode with no keystrokes.
  Exactly one of the two flags is emitted, never both.
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
- Effort vocabulary: `low|medium|high|xhigh|max`; Claude supports `max` but not `ultra`.
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

## Away-mode composer

`bin/cs-composer-lib.sh` recognizes claude's empty-composer glyph `❯` (U+276F)
alongside codex's `›`. Claude's empty composer (verified 2.1.218) is a bare `❯`
between horizontal rules with no ghost/placeholder text, so the codex ghost strip
is a harmless no-op; a bare `❯` reads `empty`, `❯ <text>` reads `pending`. The
away-mode daemon can therefore inject escalation digests into a claude composer,
same as codex.

## Permission modes (verified 2026-07-28, claude 2.1.220)

`claude --help` lists the launch flag and its accepted values:

```
  --permission-mode <mode>              Permission mode to use for the session
                                        (choices: "acceptEdits", "auto",
                                        "bypassPermissions", "manual",
                                        "dontAsk", "plan")
```

A configured mode must not cost the turn-end signal, so the Stop hook was verified
against it directly. In a scratch directory holding a `settings.json` whose `Stop`
hook touches `./turn-ended`:

```
$ claude --permission-mode auto --settings settings.json -p "Reply with exactly: OK"
OK
$ echo $?
0
$ ls turn-ended
turn-ended
```

The hook fired under `--permission-mode auto`, so `auto` keeps the same turn-end
wiring as `--dangerously-skip-permissions`. Only the three modes an unattended
soldier can actually work under are accepted by `config/permission-mode`;
`plan`, `manual`, and `dontAsk` are refused for the reasons in
`docs/configuration.md`.

NOT verified: the behavior of `--permission-mode` and `--dangerously-skip-permissions`
passed together. `cs_harness_autonomy_flag` emits exactly one of them, so the
combination never occurs in a consigliere launch.

## Native features deliberately available to consigliere

- `claude -p` / `--print` - headless non-interactive run; used for `--headless` scouts.
- `--output-format json|stream-json` - structured output, unused today.
- Herdr-native agent status (`agent_status`) auto-detects a claude agent the same as
  a codex agent, so busy/idle/done detection is harness-agnostic; the rendered-banner
  corroboration ("esc to interrupt") is shared.
