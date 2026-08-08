# Claude Code verified facts

Verified live against claude 2.1.218 on 2026-07-24 (launch-scoped Stop hook fires
and blocks; `--settings` accepts a file or JSON string; no trust prompt under
`--dangerously-skip-permissions`), against claude 2.1.220 on 2026-07-28
(`--permission-mode auto` keeps the launch-scoped Stop hook firing), and against
claude 2.1.226 on 2026-08-08 (SessionStart source vocabulary and hook-stdout
context injection; see the session-open section below).
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
  whose Claude account policy forbids the bypass flag; `config/permission-mode.conf` selects it
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
- The same file registers an unmatched, self-verifying `SessionStart` hook that
  pipes the payload into `bin/cs-sessionstart-run.sh` with a 180s timeout, above
  the digest's own 120s `CS_SESSION_START_TIMEOUT` bound so the harness never
  preempts the truncation banner.
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
  `cs_harness_detect_root` reads it (after `host/harness.conf` and `CS_HARNESS_OVERRIDE`).

## Session-open hook (verified 2026-08-08, claude 2.1.226)

Measured in a throwaway lab whose `.claude/settings.json` registered a recorder
that logs the payload `source` field and prints a source-stamped token, so
producing hook stdout can never be mistaken for delivering it into context.

Observed source vocabulary and delivery:

```
$ claude -p 'Reply with exactly the HOOK_TOKEN line you were given at session start...'
HOOK_TOKEN_startup_54208            # recorder logged source=startup
$ claude --continue -p 'Reply with exactly the LAST HOOK_TOKEN line you were given...'
HOOK_TOKEN_resume_60677             # recorder logged source=resume
```

- A scripted interactive TUI open also logged `source=startup` and the model
  quoted the fresh token back, so cold-open delivery holds in both `-p` and the TUI.
- `/clear` in the TUI logged `source=clear`, injected a fresh token, and the model
  quoted `HOOK_TOKEN_clear_21204` back.
- `/compact` is NOT verified live: repeated scripted TUI attempts (including after a
  900-word generated turn) produced no `source=compact` event and no `Compacted`
  marker in the transcript, so only claude's documented vocabulary names it.
  `bin/cs-sessionstart-run.sh` routes `clear` and `compact` identically, so routing
  does not depend on the unverified name.
- Delivery truncates from the TAIL: a ~55KB recorder payload (1000 filler lines
  between BIGTOKEN_FIRST/BIGTOKEN_LAST markers) reached the model with the first
  marker visible and the last MISSING. The digest's fleet-state-before-context
  ordering (PR #42) exists for exactly this failure mode.
- `-p` runs the project `SessionStart` hook without folder trust, but the
  interactive TUI shows the one-time "Quick safety check: Is this a project you
  created or one you trust?" dialog first and runs project hooks only after it is
  accepted.

End to end against this repo's real tracked hooks, in a plain clone with `state/`
present:

```
$ claude -p 'Do not run any tools. If a SESSION START digest is already present in your context ... reply with its LOCK section first line and DIGEST PRESENT ...'
lock acquired: harness pid 61190 DIGEST PRESENT
```

A hook-run digest stacks four to five more shells between `cs-lock.sh` and the
harness process than a directly invoked one, which is why its ancestry walk is
sixteen hops (see `bin/cs-lock.sh`).
A fresh clone WITHOUT `state/` stays silent by design (`cs_primary_scope_matches`
requires it); the first session of a brand-new home runs `bin/cs-session-start.sh`
by hand per AGENTS.md section 3.

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
soldier can actually work under are accepted by `config/permission-mode.conf`;
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
