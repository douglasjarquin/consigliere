# Codex verified facts

Verified against codex-cli 0.139-0.144 (upstream firstmate evidence) and re-verified live on 2026-07-27 with `codex --version` returning `codex-cli 0.145.0`.
`codex debug models` reported `low,medium,high,xhigh,max,ultra` for both `gpt-5.6-sol` and `gpt-5.6-terra`.
Session-open hook facts below were verified live on 2026-08-08 against codex-cli 0.146.0 and, after codex self-updated mid-verification, re-verified against codex-cli 0.147.0.
Re-verify after codex upgrades; `bin/cs-bootstrap.sh` checks presence only, not version.

## Launch template (the only one)

```
codex [--model <m>] [-c 'model_reasoning_effort="<low|medium|high|xhigh|max|ultra>"'] \
  --dangerously-bypass-approvals-and-sandbox \
  -c "notify=[\"bash\",\"-c\",\"touch state/<id>.turn-ended\"]" \
  "$(bin/cs-operational-input.sh encode launch-brief < data/<id>/brief.md)"
```

- The typed `launch-brief` positional prompt starts the supervised interactive session.
- `--dangerously-bypass-approvals-and-sandbox` gives the unattended soldier full autonomy (no trust dialog).
- The `notify` hook fires at every turn end, touching the task's turn-ended signal for the watcher.
- Effort vocabulary: `low|medium|high|xhigh|max|ultra`; Codex supports all six levels and cs-spawn passes the selected value.
- A capo launch omits the notify hook (a capo is a supervisor, not a supervised turn-taker) and prefixes `CS_HOME=<home>`.

## Hooks (.codex/hooks.json)

- `Stop` hook -> `bin/cs-turnend-guard.sh`: exit 2 + stderr blocks the stop; payload field `stop_hook_active=true` marks an already-forced continuation (loop guard).
- `SessionStart` hook -> `bin/cs-sessionstart-run.sh` (payload piped on stdin, 180s timeout, above the digest's own 120s `CS_SESSION_START_TIMEOUT` bound).
- Hook commands self-verify: they run only when the checkout's own `.codex/hooks.json` still registers them, so a copied hooks file cannot fire against a foreign tree.
- Project hooks additionally require codex's own persisted hook trust: `~/.codex/config.toml` records a `[hooks.state."<hooks.json path>:<event>:<i>:<j>"]` entry with a `trusted_hash`, an untrusted or hash-changed hook is silently skipped, and `--dangerously-bypass-hook-trust` runs enabled hooks without that record (used only by vetted automation such as the live tests).
- Consequence: after any change to `.codex/hooks.json` lands, the next interactive codex session in that home must re-approve the changed hooks once before they fire.

## Session-open hook (verified 2026-08-08, codex-cli 0.146.0 and 0.147.0)

Measured in a throwaway lab whose `.codex/hooks.json` registered a recorder that logs the payload `source` field and prints a source-stamped token, so producing hook stdout can never be mistaken for delivering it into context.

```
$ codex exec --skip-git-repo-check --dangerously-bypass-hook-trust 'Reply with exactly the HOOK_TOKEN line you were given at session start...'
HOOK_TOKEN_startup_91786            # recorder logged source=startup
$ codex exec resume --last --skip-git-repo-check --dangerously-bypass-hook-trust 'Reply with exactly the LAST HOOK_TOKEN line you were given...'
HOOK_TOKEN_resume_1362              # recorder logged source=resume
```

- The interactive TUI also fires `SessionStart` at cold open (recorder logged `source=startup` at 0.146.0 and 0.147.0) and injects the hook stdout into model context: the session rollout under `~/.codex/sessions/` shows the token as a `response_item` BEFORE the first user turn, and the model quoted it back.
  Upstream firstmate recorded "no TUI fire" at 0.146.0 from a lab without persisted hook trust, so the trust gate is the variable that finding and this one disagree on.
- A ~55KB recorder payload (1000 filler lines between BIGTOKEN_FIRST/BIGTOKEN_LAST markers) was delivered whole under `codex exec`: the model quoted both the first and last marker lines back.
- Sources other than `startup` and `resume` were not observed from codex; `bin/cs-sessionstart-run.sh` treats anything unrecognized as a full startup, which is the safe direction.

End to end against this repo's real tracked hooks, in a plain clone with `state/` present, both `codex exec` and the scripted interactive TUI delivered the full digest before the first turn:

```
$ codex exec --skip-git-repo-check --dangerously-bypass-hook-trust 'Do not run any tools. If a SESSION START digest is already present in your context ... reply with its LOCK section first line and DIGEST PRESENT ...'
lock acquired: harness pid 70271
DIGEST PRESENT
```

The TUI run's rollout recorded `lock acquired: harness pid 84353` followed by the model's `DIGEST PRESENT` reply.

## Interaction facts

- Skill invocation is `$<skill>` (codex rejects claude's `/<skill>` form); sends of `$...` need a pre-Enter settle so the completion popup does not swallow the Enter (cs-send owns this).
- Codex queues input submitted mid-turn and processes it after the turn (cs-send reports `queued`); textual sends carry the `watcher` operational kind except for the byte-compatible capo-routing kind.
- Composer ghost-text (dim inline suggestions) can make an empty composer look non-empty in captures; the away-mode composer gate must strip ANSI de-emphasis before judging emptiness (ported incident, 2026-07-08 upstream).
- Session resume is **cwd-keyed, not id-keyed**. codex records every session by working directory under `~/.codex/sessions/` (the rollout's `payload.cwd`), and `codex resume --last` continues the most recent session FOR THE CURRENT CWD by default (`--all` disables that cwd filter; verified codex 0.144, 2026-07-22). Because every soldier owns a unique worktree cwd, running `codex resume --last` from that worktree recovers exactly its own session with full context - no session id needs to be captured at spawn. `codex resume <uuid>` also works when an id is known (printed on quit), but recovery never depends on capturing it. See `skills/stuck-soldier-recovery`.

## Native features deliberately available to consigliere

- `codex exec` - headless non-interactive run; used for `--headless` scouts (turn-end = process exit; the launch line appends the terminal `done:`/`failed:` status event, so completion surfaces through the watcher's ordinary signal path). The analog of `claude -p`.
- `codex review` / `codex apply` - candidates for the no-mistakes rewrite, not used by consigliere directly.
- `codex fork/archive/delete` - session lifecycle, unused.
- Codex Desktop (`codex app`) is not a runtime surface for consigliere.
