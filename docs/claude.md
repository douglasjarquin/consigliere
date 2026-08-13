# Claude Code verified facts

Verified live against claude 2.1.218 on 2026-07-24 (launch-scoped Stop hook fires
and blocks; `--settings` accepts a file or JSON string; the folder-trust dialog is
NOT suppressed by `--dangerously-skip-permissions`, only by `-p`), against claude
2.1.220 on 2026-07-28
(`--permission-mode auto` keeps the launch-scoped Stop hook firing), and against
claude 2.1.226 on 2026-08-08 (SessionStart source vocabulary and hook-stdout
context injection; see the session-open section below).
Re-verify after claude upgrades; `bin/cs-bootstrap.sh` checks presence only, not
version. The launch template and per-harness facts live in `bin/cs-harness-lib.sh`.

## Launch template (the only one)

An interactive soldier or capo launches via herdr's native `agent start`, not a typed
shell command: `herdr agent start <id> --kind claude --pane <p> --timeout <ms> --
<--dangerously-skip-permissions | --permission-mode <mode>> [--settings <file>]`.
Everything after `--` reaches the `claude` binary as literal argv, with no shell
evaluation - `bin/cs-harness-lib.sh`'s `cs_harness_autonomy_argv` builds the autonomy
flag as discrete unquoted tokens for exactly this reason (its string-building sibling
`cs_harness_autonomy_flag`, still used only by the headless scout below, shell-quotes
the `--permission-mode` value, which would reach a native `agent start` call as the
literal 5-character string `'auto'`).

**The brief is NOT part of this call - it cannot be.** `agent start`'s trailing argv
is refused outright (`invalid_agent_argument`) the moment any single token contains
an embedded newline, live-verified 2026-08-13 with a minimal two-byte repro
(`"a\nb"`); every real brief is multi-line. Instead, `bin/cs-spawn.sh` starts the
agent bare (autonomy + `--settings` only), then delivers the brief as a follow-up
prompt via `cs_herdr_agent_prompt_confirmed` (`bin/cs-herdr-lib.sh`) - native
`agent prompt --wait --until working`, the same primitive every other prompt into
an agent's pane uses, so a multi-line brief needs no new delivery mechanism.

`bin/cs-spawn.sh`'s `_cs_spawn_deliver_brief` deliberately does NOT go through
`bin/cs-prompt-lib.sh`'s general-purpose `cs_prompt_guarded` guard, checking only
busy/blocked state itself before prompting. Live-verified 2026-08-13: a genuinely
fresh claude session's very first frame (nothing typed, no history) shows a
project-title banner where the composer classifier (`cs_composer_state`,
`bin/cs-composer-lib.sh`) requires a rule immediately above the composer glyph to
confirm "empty" - a frame shape distinct from every case that classifier's own test
suite covers, and one that never resolves on its own, since nothing changes the
render until a first prompt actually lands. Going through the guard here would
retry for its full window and then warn, every time, on every claude launch,
without ever actually delivering the brief. The guard's composer check exists to
stop a prompt from concatenating onto text something else already typed - a risk
that cannot apply to a pane this same spawn created moments ago, which nothing else
has ever had the chance to type into. `_cs_spawn_deliver_brief` retries for up to
`CS_SPAWN_BRIEF_DELIVER_WAIT_SECS` (default 50s): a prompt sent within ~40s of
`agent start` can be silently lost while herdr still reports `interactive_ready`
(see below), and `cs_herdr_agent_prompt_confirmed`'s own idle->working confirmation
is what catches that miss and makes a retry safe.

- `CLAUDE_CONFIG_DIR` is exported into the pane's shell BEFORE `agent start` runs,
  whenever consigliere itself runs under one. A pane is created by the long-lived
  herdr daemon, which does NOT inherit the environment of the consigliere process
  that requested it, so under a work-vs-personal subscription split a bare `claude`
  would read the default `~/.claude` store and come up unauthenticated. `agent
  start`'s trailing argv has no shell prefix-assignment support and neither it nor
  `worktree create` has an `--env` flag, so `bin/cs-spawn.sh`'s
  `_cs_spawn_env_export_confirmed` types `export CLAUDE_CONFIG_DIR=...` into the pane
  and verifies it landed (`cs_herdr_pane_run_confirmed`, native `pane wait-output`)
  before ever calling `agent start` - skipped entirely when the store is not
  overridden. This is the same store folder-trust is written to, so credentials and
  trust cannot land in two different config directories.
- `--dangerously-skip-permissions` gives the unattended soldier full autonomy (no permission prompts).
- `--permission-mode <auto|acceptEdits|bypassPermissions>` is the alternative for a home
  whose Claude account policy forbids the bypass flag; `config/permission-mode.conf` selects it
  and `docs/configuration.md` owns that schema. It is the flag form of the interactive
  Shift+Tab mode cycle, so a pane starts in the chosen mode with no keystrokes.
  Exactly one of the two flags is emitted, never both.
- Turn-end is wired via the `--settings` Stop hook, NOT an inline flag: claude has
  no codex-style `-c notify=`. cs-spawn writes a per-soldier settings file whose
  `Stop` hook touches `state/<id>.turn-ended` every turn and then runs
  `bin/cs-turnend-guard.sh` (the continuation backstop). The file's path is passed
  as one argv token (`--settings <file>`), same as the flag form.
- **Why a launch-scoped file, not `.claude/settings.json` in the worktree:** claude
  resolves a repo `.claude/settings.json` through worktrees to the MAIN checkout,
  so a file dropped in a soldier's worktree would land in the boss's real project
  tree and would not be soldier-isolated. `--settings <file>` scopes the hooks to
  the one launch.
- A capo launch omits the turn-end wiring (a capo is a supervisor, not a supervised
  turn-taker) and its env-export pre-step is unconditional rather than
  CLAUDE_CONFIG_DIR-gated: it clears every inherited `CS_*_OVERRIDE` and sets
  `CS_HOME=<home>`, every time, so a capo never inherits the ROOT session's overrides.
- Headless scout: `claude -p "<brief>"` (process exit = turn end), the analog of
  `codex exec`, unchanged - a plain process has no composer or `agent_status`
  lifecycle for `agent start` to target, so it stays on the shell-string mechanism
  (`cs_harness_scout_launch`) permanently. The env prefix goes between the
  enclosing `if` and the binary, exactly as before.
- A relaunch's resume attempt (`--continue`) triggers through `agent start` too, but
  its own success/failure is discarded: live-verified 2026-08-13 that native
  `interactive_ready` is fooled by the same brief window a "nothing to resume"
  `--continue` leaves before it exits (see docs/herdr.md). `bin/cs-spawn.sh`'s own
  process-table stabilization loop, unchanged, is what actually decides resumed vs.
  falls through to a cold launch.

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

## Stop payload and per-turn usage (verified 2026-08-08, claude 2.1.226)

Measured in a throwaway scratch directory whose `--settings` file registered a Stop hook that wrote its stdin payload to a file, run under `claude --settings <file> -p 'Reply with exactly: OK'`.

```json
{
  "session_id": "c2601700-cee9-4a2a-ab8f-0d6889785833",
  "transcript_path": "/Users/…/.claude/projects/<munged-cwd>/c2601700-….jsonl",
  "cwd": "…",
  "prompt_id": "81415d4e-d9ac-4379-8dac-72a24b27b22b",
  "permission_mode": "auto",
  "effort": {"level": "high"},
  "hook_event_name": "Stop",
  "stop_hook_active": false,
  "last_assistant_message": "OK",
  "background_tasks": [],
  "session_crons": []
}
```

- `effort.level` is on the payload; the model is not.
- The payload carries `prompt_id` and no `turn_id`, the inverse of codex's Stop payload; `docs/telemetry.md` owns the rule that uses that pair to name the harness that produced a turn.
- Every hook command registered under one Stop matcher receives this same payload on stdin, so a second command can read it without touching the first.
- `transcript_path` points at the session JSONL, which is the only per-turn usage source.

Each `type:"assistant"` transcript record carries `message.model`, a top-level `effort`, and `message.usage`:

```
$ jq -c 'select(.type=="assistant") | {model:.message.model, effort, id:.message.id, u:.message.usage}' <session>.jsonl | tail -1
{"model":"claude-opus-5","effort":"xhigh","id":"msg_011CdqVHPXtsMYBAHdfiN8jk","u":{"input_tokens":1,"cache_creation_input_tokens":13327,"cache_read_input_tokens":156412,"output_tokens":11255,…}}
```

- Usage fields are `input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens`; `input_tokens` EXCLUDES both cache figures, the opposite of codex's subset convention.
- There is no separate reasoning-token field: thinking tokens are inside `output_tokens`.
- One assistant message appears as SEVERAL streaming snapshot records sharing one `message.id` and one final usage object. In one measured session 38 assistant rows carried only 12 distinct ids, so summing rows without deduplicating by `message.id` would roughly triple a turn's tokens.
- `bin/cs-telemetry-lib.sh` consumes exactly these fields; `docs/telemetry.md` owns the normalization and where it is approximate.

A claude SOLDIER's turn end is its launch-scoped `--settings` Stop hook, which does receive this payload, so a claude worker turn is measurable in tokens as well as in count.

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
  A soldier runs interactive, which is why `cs_harness_claude_trust_dir` pre-trusts
  every fresh worktree at spawn.
  Codex has the same dialog and the same non-bypass and is pre-trusted the same way;
  `docs/codex.md` owns that pair's contract.

End to end against this repo's real tracked hooks, in a plain clone with `state/`
present:

```
$ claude -p 'Do not run any tools. If a SESSION START digest is already present in your context ... reply with its LOCK section first line and DIGEST PRESENT ...'
lock acquired: harness pid 61190 DIGEST PRESENT
```

A hook-run digest stacks four to five more shells between `cs-lock.sh` and the
harness process than a directly invoked one, which is why its ancestry walk is
sixteen hops (see `bin/cs-session-pid-lib.sh`, which owns the walk).
A fresh clone WITHOUT `state/` stays silent by design (`cs_primary_scope_matches`
requires it); the first session of a brand-new home runs `bin/cs-session-start.sh`
by hand per AGENTS.md section 3.

## Away-mode composer (re-verified live 2026-08-11, claude 2.1.227, isolated herdr lab)

`bin/cs-composer-lib.sh` recognizes claude's empty-composer glyph `❯` (U+276F)
alongside codex's `›`, and claude's empty composer carries no ghost/placeholder
text, so the codex ghost strip is a harmless no-op.

The glyph alone is NOT enough, because `❯` is also the prompt character of common
zsh themes.
Captured with `pane read --lines 20 --format ansi` in a named non-`default` lab,
these are the two rows that collide (long runs abbreviated `{x53}`):

```text
live claude, empty composer          dead shell, agent exited via /exit
\033[0m\033[38;2;136;136;136m─{x53}\033[0m\r   \033[0m\033[38;5;4m<cwd>\033[0m \033[0m\033[38;5;3m14s\033[0m \r
❯\xa0\r                                        \033[0m\033[38;5;5m❯\033[0m
\033[0m\033[38;2;136;136;136m─{x53}\033[0m\r
```

Three facts the bytes settle:

- Claude's composer row is `❯` followed by U+00A0 (NBSP), NOT a plain space, and
  it carries no SGR of its own.
  The NBSP normalization is what makes it read empty.
- Claude draws the composer BETWEEN 53-column `─` rules (truecolour
  `38;2;136;136;136`).
  The dead shell's `❯` has the zsh path/duration row above it and no rule.
- Colour cannot separate them: the shell's `❯` is 256-colour `38;5;5` and the
  agent's is plain here, but both are theme-dependent and neither is proof.

Verdicts from the fixed classifier, run against those exact capture files:

```
                                 agent process present   agent process gone
live claude, empty composer      empty                   unknown
live claude, typed text          pending                 pending
dead shell after /exit           unknown                 unknown
```

Before the fix the dead-shell capture read `empty`, which is the verdict that
authorizes a guarded caller (`bin/cs-prompt-lib.sh`'s composer guard, shared by
every one) to type into the pane - a login shell would have EXECUTED it.
`bin/cs-composer-lib.sh`'s header owns the resulting rule; `tests/cs-composer-lib.test.sh` pins these captures as regressions.

Corroborating signals recorded from the same run, after `/exit`:

```
$ herdr agent get w1:p1 --session <lab>
{"error":{"code":"agent_not_found","message":"agent target w1:p1 not found"},"id":"cli:agent:get"}
$ herdr pane process-info --pane w1:p1 --session <lab> | jq -r '.result.process_info.foreground_processes[].argv0'
zsh
```

NOT re-verified here: whether `--dangerously-skip-permissions` suppresses the
one-time folder-trust dialog.
In a brand-new cwd on 2.1.227 the interactive TUI
showed "Quick safety check: Is this a project you created or one you trust?"
despite that flag, and the capture run had to accept it before claude drew a
composer.

**Gap found, verified live 2026-08-13: the classifier misreads a genuinely fresh
session's very first composer, forever.** A bare `agent start` with no positional
prompt, once past the folder-trust dialog, settles into a steady-state render this
classifier never sees as `empty`:

```text
 Survey consigliere substrate simplification
opportunities ──
❯
─────────────────────────────────────────────────────
────────
  ⚠ Transcript saving is off — inherited CLAUDE_CODE…
```

The project-title banner ("Survey consigliere...opportunities ──") sits directly
above the `❯` row instead of the rule the classifier requires there for `proven=1`
on the unbordered-glyph branch (`bin/cs-composer-lib.sh`'s `cs_composer_state`,
`'❯'*') proven=$prev_rule`), so `cs_composer_state` returns `unknown` - not a
transient startup delay: re-read 5+ seconds later, byte-identical, still
`unknown`. This is a genuinely new frame shape, distinct from every case
`tests/cs-composer-lib.test.sh` already covers (ghost-composer, typed-input,
dead-shell, stale-composer-above-dead-shell), and it never resolves on its own -
nothing changes this render until a prompt actually lands, which is exactly what
`cs_composer_state`'s "empty" verdict is supposed to authorize. Retrying
`bin/cs-prompt-lib.sh`'s `cs_prompt_guarded` against this pane for any length of
time never succeeds. `bin/cs-spawn.sh`'s initial-brief delivery works around this
by not using that guard for this one call (see the launch template above); nothing
else in the fleet currently prompts a bare-just-launched pane with no other
caller between `agent start` and the first prompt, so nothing else hits this yet.

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

## Agent lifecycle control (verified live 2026-08-11, claude 2.1.227, isolated herdr lab)

The mechanics `bin/cs-control.sh` drives, measured the same way as the codex side (docs/codex.md).

- **Interrupt is Escape.** During a live turn one `pane send-keys <pane> esc` moved `agent_status` from `working` to `idle` within 2s; the transcript recorded `⎿ Interrupted · What should Claude do instead?` and the composer classified `empty` afterwards. Claude does not restore the cancelled prompt into the composer.
- **Exit is `/exit`.** Sent as `pane send-text '/exit'` then Enter, with NO settle (claude's completion popup does not swallow the Enter, the same asymmetry the `$skill` vs `/skill` send already has). The agent process left the pane in 2s and `agent get` returned `{"error":{"code":"agent_not_found",...}}`.
- **Unsent composer text is what breaks a lifecycle command, and it is a real, reproducible case.** A steer delivered mid-turn is QUEUED, and cancelling the turn leaves that queued line sitting in the composer:

  ```text
  queued-mid-turn:          state=empty   busy=busy
  queued-post-esc:          state=pending busy=idle     # ❯ QUEUED_SECOND_MESSAGE
  queued-after-second-esc:  state=pending busy=idle     # a second esc does NOT clear it
  ```

  Typing the exit command onto it submits the concatenation as a prompt, and the agent reasons about it instead of exiting: `⏺ No task in message. /exit is CLI built-in - type it directly in terminal to quit session.` Cancelling a turn with NOTHING queued leaves the composer empty, measured repeatedly over 15s. Since herdr has no key that clears a composer (docs/herdr.md), `bin/cs-control-lib.sh` submits the line with one Enter, cancels the turn it starts, and then types the exit command regardless of what the classifier still says - the verified postcondition decides the outcome, because a row that survives the flush is not unsent input (the shell-prompt collision below is what it usually is).
- **The zsh prompt glyph collides with claude's composer glyph, and the collision is visible in a real soldier pane.** Sampled from a live `cs-spawn`ed soldier at mode `--format ansi`, the row `cs_composer_state` matched immediately after launch was the pane's SHELL prompt, not claude's composer:

  ```text
  \033[0m\033[38;5;5m❯\033[0m \033[38;5;2mclaude\033[0m --dangerously-skip-permissions --settings \033[38;5;3m'/…
  ```

  A 256-colour foreground (`38;5;n`) is deliberately KEPT by `cs_composer_strip_ghost`, so that row classified `pending` while the agent's own composer classifies `empty` correctly once claude has drawn it. Consequence for this plane: the flush above exists partly because `pending` is not always real typed text. The worse consequence - a pane whose agent has EXITED shows a BARE `❯` shell prompt that read `empty` - was fixed separately; the away-mode composer section above owns the evidence and the rule.
- **`claude --continue` with nothing to resume fails cleanly, but not instantly.** In a fresh directory it printed `No conversation found to continue`, exited rc 1, and left the pane at its shell with no agent process - the positively-agent-free signal `bin/cs-spawn.sh --relaunch` waits for before falling back to a cold launch. It is a real process while it does that, and herdr's detector reports an agent in the pane for that second, so "an agent appeared" alone is NOT proof a resume took: the relaunch requires the agent to still be there, with a readable process, after a settle.
- **A resumed session keeps its id.** `agent_session.value` was byte-identical before the exit and after the resume, so it cannot be used as relaunch evidence (docs/herdr.md owns that conclusion).
- **A finished claude turn does not necessarily read `idle`.** `herdr agent wait <pane> --until idle` timed out against a live claude soldier whose turn had provably ended (its Stop hook had already touched the turn-end file), because herdr reported native `done`, which the status policy maps to `done` and not to `idle` (docs/herdr.md). Wait on the corroborated busy state (`cs_herdr_agent_busy_state` is not `busy`), which is what every consigliere caller acts on; `tests/cs-lifecycle-claude-live.test.sh` does, after the raw wait failed a healthy agent.
- NOT measurable in a lab launched from a Claude Code session: a real resume. A nested claude inherits `CLAUDE_CODE_CHILD_SESSION` and starts with `⚠ Transcript saving is off`, so it records no resumable session at all. The production evidence for the resume path is the per-worktree session store: each soldier worktree has its own `~/.claude/projects/<munged-cwd>/<session>.jsonl`, which is what `--continue` reads.

## Native features deliberately available to consigliere

- `claude -p` / `--print` - headless non-interactive run; used for `--headless` scouts.
- `--output-format json|stream-json` - structured output, unused today.
- Herdr-native agent status (`agent_status`) auto-detects a claude agent the same as
  a codex agent, so busy/idle/done detection is harness-agnostic; the rendered-banner
  corroboration ("esc to interrupt") is shared.
