# Codex verified facts

Verified against codex-cli 0.139-0.144 (upstream firstmate evidence) and re-verified live on 2026-07-27 with `codex --version` returning `codex-cli 0.145.0`.
`codex debug models` reported `low,medium,high,xhigh,max,ultra` for both `gpt-5.6-sol` and `gpt-5.6-terra`.
Session-open hook facts below were verified live on 2026-08-08 against codex-cli 0.146.0 and, after codex self-updated mid-verification, re-verified against codex-cli 0.147.0.
Re-verify after codex upgrades; `bin/cs-bootstrap.sh` checks presence only, not version.

## Launch template (the only one)

```
codex --dangerously-bypass-approvals-and-sandbox \
  -c "notify=[\"bash\",\"-c\",\"touch state/<id>.turn-ended\"]" \
  "$(bin/cs-operational-input.sh encode launch-brief < data/<id>/brief.md)"
```

- The typed `launch-brief` positional prompt starts the supervised interactive session.
- `--dangerously-bypass-approvals-and-sandbox` gives the unattended soldier full autonomy (no trust dialog).
- The `notify` hook fires at every turn end, touching the task's turn-ended signal for the watcher.
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

## Stop payload and per-turn usage (verified 2026-08-08, codex-cli 0.147.0)

Measured in a throwaway scratch directory whose `.codex/hooks.json` registered a Stop hook that appended its stdin payload to a file, run under `codex exec --skip-git-repo-check --dangerously-bypass-hook-trust 'Reply with exactly: OK'`.

```json
{
  "session_id": "019fe1ea-df85-7a02-932b-d0ed71bdff54",
  "turn_id": "019fe1ea-e03b-7bb1-abc1-54fecaeb5cca",
  "transcript_path": "/Users/…/.codex/sessions/2026/08/08/rollout-2026-08-08T11-08-14-019fe1ea-df85-7a02-932b-d0ed71bdff54.jsonl",
  "cwd": "…",
  "hook_event_name": "Stop",
  "model": "gpt-5.6-sol",
  "permission_mode": "bypassPermissions",
  "stop_hook_active": false,
  "last_assistant_message": "OK"
}
```

- The Stop hook fired exactly ONCE per turn: a second run with an APPENDING recorder captured one payload for one turn, so the turn-end path is not a double-fire.
- `model` is on the payload; `effort` is not.
- The payload carries `turn_id` and no `prompt_id`, the inverse of claude's Stop payload; `docs/telemetry.md` owns the rule that uses that pair to name the harness that produced a turn.
- `transcript_path` points at the session rollout, which is the only per-turn usage source.

The rollout carries usage and turn identity as ordinary records:

```
$ jq -c 'select(.payload.type=="token_count") | .payload.info.last_token_usage' rollout-….jsonl
{"input_tokens":28820,"cached_input_tokens":6912,"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":28825}
$ jq -c 'select(.type=="turn_context") | {model:.payload.model, effort:.payload.effort, turn:.payload.turn_id}' rollout-….jsonl
{"model":"gpt-5.6-sol","effort":"ultra","turn":"019fe1ea-e03b-7bb1-abc1-54fecaeb5cca"}
$ jq -c 'select(.payload.type=="task_complete") | {turn_id:.payload.turn_id, duration_ms:.payload.duration_ms}' rollout-….jsonl
{"turn_id":"019fe1ea-e03b-7bb1-abc1-54fecaeb5cca","duration_ms":5417}
```

- `event_msg`/`token_count` records `info.last_token_usage` per model request and `info.total_token_usage` cumulatively; `cached_input_tokens` is a SUBSET of `input_tokens`, not an addition to it.
- `turn_context.turn_id` and `task_complete.turn_id` both match the Stop payload's `turn_id`.
- `event_msg`/`token_count` also carries a `rate_limits` block (percent used, window, reset epoch, plan type); consigliere does not read it.
- `bin/cs-telemetry-lib.sh` consumes exactly these fields; `docs/telemetry.md` owns what is done with them.

A codex SOLDIER's turn end is the `notify` program, which is invoked with the notification JSON as an ARGUMENT and no piped payload, and that notification carries no usage.
So a codex worker turn is measurable in count, role, and task identity, but not in tokens.

## Interaction facts

- Skill invocation is `$<skill>` (codex rejects claude's `/<skill>` form); sends of `$...` need a pre-Enter settle so the completion popup does not swallow the Enter (cs-send owns this).
- Codex queues input submitted mid-turn and processes it after the turn (cs-send reports `queued`); textual sends carry the `watcher` operational kind except for the byte-compatible capo-routing kind.
- Composer ghost-text (dim inline suggestions) can make an empty composer look non-empty in captures; the away-mode composer gate must strip ANSI de-emphasis before judging emptiness (ported incident, 2026-07-08 upstream).
- Session resume is **cwd-keyed, not id-keyed**. codex records every session by working directory under `~/.codex/sessions/` (the rollout's `payload.cwd`), and `codex resume --last` continues the most recent session FOR THE CURRENT CWD by default (`--all` disables that cwd filter; verified codex 0.144, 2026-07-22). Because every soldier owns a unique worktree cwd, running `codex resume --last` from that worktree recovers exactly its own session with full context - no session id needs to be captured at spawn. `codex resume <uuid>` also works when an id is known (printed on quit), but recovery never depends on capturing it. See `skills/stuck-soldier-recovery`.

## Agent lifecycle control (verified live 2026-08-11, codex-cli 0.147.0, isolated herdr lab)

The mechanics `bin/cs-control.sh` drives, each measured in a lab pane rooted in a throwaway git repo.

- **Interrupt is Escape.** During a live turn (`agent_status: working`) one `pane send-keys <pane> esc` moved the status to `idle` within 2s and the transcript recorded `■ Conversation interrupted - tell the model what to do differently`. The composer was EMPTY afterwards (its `›` row carried only codex's dim ghost suggestion), so no composer clear is needed and none is available (docs/herdr.md: herdr refuses `C-u`).
- **A second Escape is not a retry.** Codex reads Escape twice at an idle composer as "edit the previous message", so an unconfirmed interrupt is reported rather than re-sent.
- **Exit is `/quit`.** Sent as `pane send-text '/quit'`, a 1.5s settle, then Enter (the settle is the same completion-popup guard `$skill` sends need). The agent process left the pane within the 30s bound, `agent get` returned `{"error":{"code":"agent_not_found",...}}`, and the pane's shell came back carrying codex's own hint:

  ```text
  To continue this session, run codex resume 019ff0a3-7d80-7072-aa6b-3ebf889a8d97
  repo main
  ❯
  ```

- **The launch flags work after the `resume` subcommand.** `codex resume --help` (0.147.0) lists `-c` and `--dangerously-bypass-approvals-and-sandbox`, and the live relaunch line

  ```text
  codex resume --last --dangerously-bypass-approvals-and-sandbox -c "notify=[...]"
  ```

  brought up a new agent process (pid 43908 -> 63210) whose transcript still held the pre-exit conversation, including the interrupted prompt. That is what makes resume-first worth preferring: the soldier keeps its context.
- **Directory trust blocks an unattended launch.** A codex TUI started in a directory it does not trust sits at `Do you trust the contents of this directory?` and herdr reports `agent_status: blocked` with the codex process still running. So a relaunch that cannot confirm the pane is agent-free must refuse rather than launch again - a blocked codex is present, not absent.
- NOT established here: whether `-c notify=` still fires at turn end on 0.147.0. The lab's turn-end file was never touched although the same session's `SessionStart` hooks did run, and codex's persisted hook trust (above) is the obvious suspect. The launch template is unchanged by the control plane, so this is a standing question about the codex turn-end signal, not about relaunch.

## Native features deliberately available to consigliere

- `codex exec` - headless non-interactive run; used for `--headless` scouts (turn-end = process exit; the launch line appends the terminal `done:`/`failed:` status event, so completion surfaces through the watcher's ordinary signal path). The analog of `claude -p`.
- `codex review` / `codex apply` - candidates for the no-mistakes rewrite, not used by consigliere directly.
- `codex fork/archive/delete` - session lifecycle, unused.
- Codex Desktop (`codex app`) is not a runtime surface for consigliere.
