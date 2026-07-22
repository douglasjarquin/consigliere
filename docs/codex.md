# Codex verified facts

Verified against codex-cli 0.139-0.144 (upstream firstmate evidence) and re-verified live on 2026-07-22 (spawn, native herdr agent detection, steer).
Re-verify after codex upgrades; `bin/cs-bootstrap.sh` checks presence only, not version.

## Launch template (the only one)

```
codex [--model <m>] [-c 'model_reasoning_effort="<low|medium|high|xhigh>"'] \
  --dangerously-bypass-approvals-and-sandbox \
  -c "notify=[\"bash\",\"-c\",\"touch state/<id>.turn-ended\"]" \
  "$(cat data/<id>/brief.md)"
```

- Positional prompt starts the supervised interactive session.
- `--dangerously-bypass-approvals-and-sandbox` gives the unattended soldier full autonomy (no trust dialog).
- The `notify` hook fires at every turn end, touching the task's turn-ended signal for the watcher.
- Effort vocabulary: `low|medium|high|xhigh`; `max` is not in the bundled catalog and is refused by cs-spawn rather than passed.
- A capo launch omits the notify hook (a capo is a supervisor, not a supervised turn-taker) and prefixes `CS_HOME=<home>`.

## Hooks (.codex/hooks.json)

- `Stop` hook -> `bin/cs-turnend-guard.sh`: exit 2 + stderr blocks the stop; payload field `stop_hook_active=true` marks an already-forced continuation (loop guard).
- Hook commands self-verify: they run only when the checkout's own `.codex/hooks.json` still registers them, so a copied hooks file cannot fire against a foreign tree.

## Interaction facts

- Skill invocation is `$<skill>` (codex rejects claude's `/<skill>` form); sends of `$...` need a pre-Enter settle so the completion popup does not swallow the Enter (cs-send owns this).
- Codex queues input submitted mid-turn and processes it after the turn (cs-send reports `queued`).
- Composer ghost-text (dim inline suggestions) can make an empty composer look non-empty in captures; the away-mode composer gate must strip ANSI de-emphasis before judging emptiness (ported incident, 2026-07-08 upstream).
- `codex resume <session-id>` resumes an exited session; capturing the session id at spawn is an open item (fallback: relaunch with brief + context).

## Native features deliberately available to consigliere

- `codex exec` - headless non-interactive run; planned as the `--headless` scout option (turn-end = process exit, done = exit + report exists).
- `codex review` / `codex apply` - candidates for the no-mistakes rewrite, not used by consigliere directly.
- `codex fork/archive/delete` - session lifecycle, unused.
- Codex Desktop (`codex app`) is not a runtime surface for consigliere.
