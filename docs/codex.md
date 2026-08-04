# Codex verified facts

Verified against codex-cli 0.139-0.144 (upstream firstmate evidence), re-verified live on 2026-07-27 with `codex --version` returning `codex-cli 0.145.0`, and again on 2026-08-03 at `codex-cli 0.146.0` (folder trust and post-turn status, below).
`codex debug models` reported `low,medium,high,xhigh,max,ultra` for both `gpt-5.6-sol` and `gpt-5.6-terra`.
Re-verify after codex upgrades; `bin/cs-bootstrap.sh` checks presence only, not version.

## Launch template (the only one)

```
codex [--model <m>] [-c 'model_reasoning_effort="<low|medium|high|xhigh|max|ultra>"'] \
  --dangerously-bypass-approvals-and-sandbox \
  -c "notify=[\"bash\",\"-c\",\"touch state/<id>.turn-ended\"]" \
  "$(bin/cs-operational-input.sh encode launch-brief < data/<id>/brief.md)"
```

- The typed `launch-brief` positional prompt starts the supervised interactive session.
- The `--dangerously-bypass-approvals-and-sandbox` flag gives the unattended soldier full autonomy over approvals and the sandbox, but it does not suppress Codex's folder-trust dialog; see `Folder trust and the false idle` below.
- The `notify` hook fires at every turn end, touching the task's turn-ended signal for the watcher.
- Effort vocabulary: `low|medium|high|xhigh|max|ultra`; Codex supports all six levels and cs-spawn passes the selected value.
- A capo launch omits the notify hook (a capo is a supervisor, not a supervised turn-taker) and prefixes `CS_HOME=<home>`.

## Hooks (.codex/hooks.json)

- `Stop` hook -> `bin/cs-turnend-guard.sh`: exit 2 + stderr blocks the stop; payload field `stop_hook_active=true` marks an already-forced continuation (loop guard).
- Hook commands self-verify: they run only when the checkout's own `.codex/hooks.json` still registers them, so a copied hooks file cannot fire against a foreign tree.

## Interaction facts

- Skill invocation is `$<skill>` (codex rejects claude's `/<skill>` form); sends of `$...` need a pre-Enter settle so the completion popup does not swallow the Enter (cs-send owns this).
- Codex queues input submitted mid-turn and processes it after the turn (cs-send reports `queued`); textual sends carry the `watcher` operational kind except for the byte-compatible capo-routing kind.
- Composer ghost-text (dim inline suggestions) can make an empty composer look non-empty in captures; the away-mode composer gate must strip ANSI de-emphasis before judging emptiness (ported incident, 2026-07-08 upstream).
- Session resume is **cwd-keyed, not id-keyed**. codex records every session by working directory under `~/.codex/sessions/` (the rollout's `payload.cwd`), and `codex resume --last` continues the most recent session FOR THE CURRENT CWD by default (`--all` disables that cwd filter; verified codex 0.144, 2026-07-22). Because every soldier owns a unique worktree cwd, running `codex resume --last` from that worktree recovers exactly its own session with full context - no session id needs to be captured at spawn. `codex resume <uuid>` also works when an id is known (printed on quit), but recovery never depends on capturing it. See `skills/stuck-soldier-recovery`.

## Folder trust and the false `idle` (verified 2026-08-03, herdr 0.7.5, codex-cli 0.146.0)

`--dangerously-bypass-approvals-and-sandbox` does NOT bypass codex's folder-trust dialog, exactly as `--dangerously-skip-permissions` does not bypass claude's.
Launched interactively into a worktree whose repository root is not covered by `~/.codex/config.toml`, a codex soldier stops at:

```text
  Do you trust the contents of this directory?
› 1. Yes, continue
  2. No, quit
```

While it waits there, `agent get` reports `agent_status: idle` and the `notify` hook never fires, so `state/<id>.turn-ended` stays absent.
That is the trap: `idle` looks identical to "resting between turns", and `cs_herdr_agent_wait_present` is satisfied because an agent genuinely IS in the pane.
Answering the dialog releases it into the real turn, which then reads `working` and settles on `done`:

```text
  5s status=idle     turn-ended=no     # sitting at the trust dialog
 10s status=working  turn-ended=no     # released after Enter
 20s status=done     turn-ended=yes
```

Trust is recorded as a `[projects."<path>"] trust_level = "trusted"` table in `~/.codex/config.toml`.
The boss's config trusts `/Users/douglasjarquin`, and every fleet worktree (`~/.herdr/worktrees/...`) and project clone lives under it, which is why real soldiers never see this dialog.
It bites only a repository root outside that tree - notably a test fixture under `mktemp`.

Consequences:

- Unlike claude, consigliere does NOT pre-trust a codex worktree; there is no codex counterpart to `cs_harness_claude_trust_dir`, and none is needed while the fleet stays under a trusted ancestor.
- `cs_harness_launch_env` deliberately emits nothing for codex, so there is no seam for pointing a codex launch at an isolated config.
  Any test that needs an untrusted fixture repo to actually take a turn needs that seam first.
- `tests/cs-lifecycle-live.test.sh` is affected and says so in its header: its fixture repo is never trusted, so the suite does not prove a codex turn ran, and its steer lands in the dialog and accepts it - appending a permanent trust entry for a temp path to the boss's real config on every run.

## Native features deliberately available to consigliere

- `codex exec` - headless non-interactive run; used for `--headless` scouts (turn-end = process exit; the launch line appends the terminal `done:`/`failed:` status event, so completion surfaces through the watcher's ordinary signal path). The analog of `claude -p`.
- `codex review` / `codex apply` - candidates for the no-mistakes rewrite, not used by consigliere directly.
- `codex fork/archive/delete` - session lifecycle, unused.
- Codex Desktop (`codex app`) is not a runtime surface for consigliere.
