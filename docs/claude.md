# Claude Code verified facts

Verified live against claude 2.1.218 on 2026-07-24 (launch-scoped Stop hook fires
and blocks; `--settings` accepts a file or JSON string; no trust prompt under
`--dangerously-skip-permissions`), and against claude 2.1.220 on 2026-07-28
(`--permission-mode auto` keeps the launch-scoped Stop hook firing).
Re-verify after claude upgrades; `bin/cs-bootstrap.sh` checks presence only, not
version. The launch template and per-harness facts live in `bin/cs-harness-lib.sh`.

## Launch template (the only one)

```
[CLAUDE_CONFIG_DIR=<dir>] claude [--model <m>] [--effort <low|medium|high|xhigh|max>] \
  <--dangerously-skip-permissions | --permission-mode <mode>> \
  --settings <state/<id>.claude-settings.json> \
  "$(bin/cs-operational-input.sh encode launch-brief < data/<id>/brief.md)"
```

- The typed `launch-brief` positional prompt starts the supervised interactive session.
- `CLAUDE_CONFIG_DIR` is restated on the launch line whenever consigliere itself runs
  under one. A pane is created by the long-lived herdr daemon, which does NOT inherit
  the environment of the consigliere process that requested it, so under a
  work-vs-personal subscription split a bare `claude` would read the default
  `~/.claude` store and come up unauthenticated. Unset is the single-store default and
  emits no prefix. This is the same store folder-trust is written to, so credentials
  and trust cannot land in two different config directories.
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
  turn-taker) and prefixes `CS_HOME=<home>`; the `CLAUDE_CONFIG_DIR` prefix, when
  emitted, precedes those assignments.
- Headless scout: `claude -p "<brief>"` (process exit = turn end), the analog of `codex exec`.
  The env prefix goes between the enclosing `if` and the binary.

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

## Post-turn agent status is `done`, never `idle` (verified 2026-08-03, herdr 0.7.5, claude 2.1.220)

A codex agent reads `agent_status: working` mid-turn and `idle` after the turn ends (docs/herdr.md).
A claude agent reads `working` mid-turn and **`done`** after the turn ends, and never reports `idle` at all.
`done` here means "this turn is over", not "the agent exited": the same pane accepts a steer afterwards and goes `working` again.

Spawned through `bin/cs-spawn.sh` into an isolated lab, then polled every 5s for 70s after the boot turn:

```
$ herdr agent get w3:p1 --session cs-lab-diag-claude-idle-...   # via bin/cs-herdr-lab.sh run
  5s status=done     turn-ended=yes
 10s status=done     turn-ended=yes
   ... 14 consecutive samples, all done ...
 70s status=done     turn-ended=yes
```

`turn-ended=yes` is `state/<id>.turn-ended`, so the `--settings` Stop hook had already fired: the turn was genuinely over while the status read `done`.
A steer then proves the agent is alive and reusable, not exited:

```
$ bin/cs-send.sh diag2 "Reply with exactly LIVE_STEER_OK and stop."
submitted
  4s status=working
  8s status=done
   ... holds at done ...
```

Consequences:

- Never wait on `idle` for a claude soldier: `herdr agent wait <pane> --until idle` times out against a perfectly healthy agent.
  `cs_herdr_agent_wait "$PANE" done` is the claude equivalent of the codex `idle` wait.
- Production is unaffected, and this was verified rather than assumed: the only production wait is `cs_herdr_submit_confirm`, which waits for `working`, and `cs_herdr_agent_busy_state` already maps a raw `done` to its own non-busy state (`bin/cs-herdr-lib.sh`), so the watcher and `bin/cs-crew-state.sh` never depend on claude reporting `idle`.
- `tests/cs-lifecycle-claude-live.test.sh` did depend on it, and failed on `main` for that reason alone; it now waits on `done`.

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
  a codex agent, and `cs_herdr_agent_busy_state` normalizes both, so BUSY detection is
  harness-agnostic; the rendered-banner corroboration ("esc to interrupt") is shared.
  The post-turn resting VALUE is not shared - claude reports `done` where codex reports
  `idle` - so never compare a raw `agent_status` against `idle` for a claude soldier.
  See "Post-turn agent status is `done`, never `idle`" above.
