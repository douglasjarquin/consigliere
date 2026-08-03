# Herdr verified facts

Verified against herdr 0.7.4 (protocol 16) on 2026-07-22, and re-verified against the current pin herdr 0.7.5 (protocol 17) on 2026-08-01, both in isolated lab sessions.
The CI pin (`bin/cs-install-herdr.sh`) is 0.7.5 so the required herdr lane exercises the same CLI contract the fleet runs; it was 0.7.4 until an `agent wait` flag rename broke the fleet while CI stayed green.
Re-verify this table after any herdr upgrade; `bin/cs-bootstrap.sh` gates on the minimum protocol.

## Session discipline

- Every CLI call carries an explicit trailing `--session <name>`; ambient `HERDR_SESSION` alone is not trusted (upstream firstmate evidence: unreliable once another server runs).
- The live session is `default`; tests and consigliere-on-itself lifecycle tasks use `bin/cs-herdr-lab.sh` labs named `cs-lab-*`, never `default`.
- Headless lab provisioning: `HERDR_SESSION=<name> herdr server --session <name> &`, socket at `~/.config/herdr/sessions/<name>/herdr.sock`.
- CLI subcommands emit JSON by default; there is no `--json` flag on `workspace`/`worktree` subcommands (only some, e.g. `status`, `session list`).

## Container shape: workspace-per-task

`herdr worktree create --workspace <src> --branch <name> --label <task-id> --no-focus` verified behavior:

- Creates the worktree at `~/.herdr/worktrees/<repo_name>/<branch-sanitized>` (branch `cs/t1` -> dir `cs-t1`).
- `--branch` and `--base REF` control branch creation; the branch is real and persists.
- Creates a NEW workspace bound to the worktree (the `--workspace` argument only names the source workspace whose repo is used); the response carries `workspace_id`, `tab_id`, `pane_id`, `worktree.path`, `worktree.branch`.
- The root pane IS the task pane; no seeded default tab to prune in the worktree flow.
  (The prune concern applies only to bare `workspace create`, which seeds a default tab labeled "1".)

So consigliere's shape is: one home workspace (`consigliere`, or `capo-<id>`) where the supervisor runs, plus one workspace per task, created by `worktree create` and labeled with the task id.

### Workspace labels are not unique

Herdr enforces no uniqueness on workspace labels: two workspaces may both be labeled `consigliere` or `capo-<id>`, and `workspace list` returns both.
A label is therefore a hint, never an identity.

Task placement is immune to this by construction - every ship and scout task gets a brand-new workspace from `worktree create`, so nothing is resolved by label search.
The one label lookup left is the home workspace (`cs_herdr_workspace_find` / `cs_herdr_home_workspace_ensure`), used when launching a capo.
Returning the first match there would silently bind the capo to whichever duplicate came back first, so two candidates refuse with both workspace ids named, and an ambiguous label never creates a third workspace.
The boss resolves it by closing or relabelling the duplicate.
This is the same rule already applied to tab labels below: scope to this home's workspace ids from metadata, never adopt by label sweep.

## Worktree lifecycle safety (D1 verification)

- `worktree remove --workspace <id>` on a dirty worktree fails closed: `dirty_worktree_requires_force`. `--force` is the only override.
- Clean `worktree remove` deletes the worktree directory, closes the workspace, and PRESERVES the branch (safe for PR flows).
- `workspace close <id>` does NOT delete the worktree; dirty work survives.
- Server stop/restart: workspaces are restored; a worktree whose workspace is gone is recovered with `worktree open --path <path> --label <label>` (`already_open:false` on success; binds a fresh workspace).
- `worktree list --cwd <path>` lists all worktrees of the repo with `branch`, `path`, `open_workspace_id`.
- cs-teardown still owns the landed-work proofs; `herdr worktree remove` runs only after those proofs pass and is never itself the safety mechanism.

## Native agent status (verified against live codex)

- `agent list` / `agent get <pane>` detect codex automatically (`"agent":"codex"`) with `agent_status`: `idle|working|blocked|done|unknown`.
- Mid-turn status reads `working`; after the turn ends it reads `idle`.
- `agent wait <pane> --until <status> --timeout <ms>` blocks until the status is reached (verified ~5s wait resolving on turn end); use it for submit confirmation and bounded single-target waits.
  **The flag was RENAMED between releases: 0.7.4 took `--status`, 0.7.5 takes `--until`, and each rejects the other outright.**

  ```text
  $ herdr agent wait bogus999 --status idle --timeout 200   # on 0.7.5
  unknown option: --status
  rc=2
  ```

  This is the only recorded case of a herdr CLI contract moving under a running fleet, and it cost real supervision: consigliere shipped `--status` (correct for 0.7.4, recorded verified here), herdr self-updated the boss's machine to 0.7.5, and because `cs_herdr_submit_confirm` discards both streams the usage error read as "the turn never started" - every steer burned its Enter-retry loop and reported "not confirmed" even on success, and the away daemon's strict undelivered path stayed on. CI pinned 0.7.4 and never saw it.
  Guarded three ways now: the CI pin is 0.7.5, `tests/cs-herdr-lib-live.test.sh` asserts the current spelling works AND that `--status` is rejected, and the offline fakes reject `--status` too, because a fake that matched only the subcommand is what let it ship.

- Known upstream gap (firstmate evidence, docs/herdr-backend.md): `agent get` can read `idle` during a LONG foreground tool call. Policy: native `working` is trusted outright; native `idle`/`unknown` must be corroborated against the codex busy signature (`esc to interrupt`) before a soldier is declared not-working. Single constant in `cs-herdr-lib.sh`.

## Capture

- `pane read <pane> --lines N --format text|ansi` returned exactly N lines on 0.7.4; the upstream small-`--lines` truncation bug was NOT reproduced. `cs-herdr-lib.sh` passes `--lines` through directly; if a regression appears, re-add the read-wide-then-tail workaround from firstmate's adapter.
- `pane run <pane> '<text>'` submits text plus Enter atomically (verified launching codex and steering it).
  It reports success whether or not the pane's SHELL was ready to read the line. A freshly created worktree pane frequently is not, and the line is then lost with no way to recover it from the buffer - `tests/cs-herdr-lib-live.test.sh` works around this by re-submitting an idempotent probe, and `bin/cs-spawn.sh` guards against it by requiring an agent to actually appear afterwards (`cs_herdr_agent_wait_present`). Never treat a `pane run` exit status as proof the command ran.
- Machine input uses U+2063 INVISIBLE SEPARATOR because it survives UTF-8 terminal input; the upstream herdr 0.7.3 incident showed ASCII 0x1f was stripped from the composer. `bin/cs-operational-input.sh` owns the exact bytes.

## Push events

- Multi-pane push (`events.subscribe` -> `pane.agent_status_changed`) is socket-only; no CLI subcommand.
- `bin/cs-herdr-events.py` is the raw AF_UNIX subscriber (ported from firstmate's herdr-eventwait.py); the watcher splices it in when the socket is capable and keeps the poll loop as the permanent backstop.

## Known gaps / watch list

- `worktree create` fails (`worktree_create_failed`) when the target directory `~/.herdr/worktrees/<repo_name>/<branch-sanitized>` already exists - e.g. leftovers from an aborted task whose repo clone is gone. cs-spawn must treat that as stop-and-report (a leftover directory may hold unlanded work); never pre-delete the path to make the create succeed.

- No `workspace move` CLI (method exists in `api schema`); consigliere does not order workspaces, so no shim is ported.
- Tab labels are not unique; list-live matching stays defensive (scope to this home's workspace ids from meta, never by label sweep).
- `herdr integration install codex` exists; not used yet — codex is launched directly with explicit flags so the launch template stays under consigliere's control.

## Push event subscriptions (verified live 2026-07-29, herdr 0.7.5, protocol 17)

`events.subscribe` accepts one or more subscription specs on the session control socket and streams newline-delimited JSON. Probed each spec against a real pane and recorded the server's own answer:

```text
output_matched substring+source   ACK subscription_started
output_matched regex+source       ACK subscription_started
pane.exited                       ACK subscription_started
pane.agent_detected               ACK subscription_started
worktree.removed                  ACK subscription_started
pane.closed                       ACK subscription_started
pane.output_changed               ERR invalid_request: unknown variant
```

The rejection is the authoritative capability list, because the server enumerates what it will accept:

```text
workspace.created workspace.updated workspace.metadata_updated workspace.renamed
workspace.moved workspace.closed workspace.focused worktree.created
worktree.opened worktree.removed tab.created tab.closed tab.focused tab.renamed
tab.moved pane.created pane.closed pane.updated pane.focused pane.moved
pane.exited pane.agent_detected pane.output_matched pane.agent_status_changed
pane.scroll_changed layout.updated
```

- `pane.output_changed` is a real internal event kind but is NOT subscribable. Source reading alone is misleading here: the exclusion list in `src/api/schema/events.rs` governs plugin hooks, not subscriptions. Probe the socket, do not infer from the source.
- `pane.output_matched` REQUIRES a `source` field (`visible`, `recent`, or `recent-unwrapped`); omitting it is `invalid_request`, not a default.
- `bin/cs-herdr-events.py` subscribes to `pane.agent_status_changed`, `pane.exited`, and `pane.agent_detected` per pane, plus `pane.output_matched` for each pattern in `CS_HERDR_EVENT_PATTERNS`.

### Protocol precondition

`CS_HERDR_MIN_PROTOCOL` in `bin/cs-herdr-lib.sh` is the floor (16); the live server reports 17.

Every capability above was verified at protocol 17 only, because that is the running server. They are NOT verified at 16, and this repo has no protocol-16 server to test against. So the floor deliberately stays at 16 and each new capability is gated at runtime instead of by version arithmetic: the subscribe either returns `subscription_started` or it does not, and `bin/cs-watch.sh` already treats any reader failure as "fall back to polling for this cycle". Raising the floor would trade a working fallback for a hard refusal, and would do it on an unverified assumption about which protocol first carried each event.

Re-probe after a herdr upgrade rather than trusting this table.

### Pattern policy trap

A configured `pane.output_matched` pattern means "wake the supervisor". Do not configure a benign high-volume pattern: the harness busy signature (`CS_HARNESS_BUSY_RE`, `[Ee]sc to interrupt`) renders continuously during every turn, so subscribing to it would fire an actionable wake on every frame of normal work. The intended first pattern is the claude permission prompt under `--permission-mode auto|acceptEdits`, which currently surfaces only through the slow stale path - but its exact rendered text is NOT yet verified, so no pattern ships by default. Capture it from a real pane that has stopped on a prompt, record the string here with its command and output, then configure it.

**Open verification item (blocked on environment, not on effort).** The prompt cannot be produced on the machine this was written on: codex runs there with permissions fully enabled, so it never stops to ask. It is reproducible in an environment running claude under `--permission-mode auto`, which is where this must be captured. What to record, so the pattern is written once and correctly:

1. The exact rendered prompt line(s) from `herdr pane read --pane <id>`, ansi included and then stripped, since the subscription matches against a chosen `source` rather than the raw frame.
2. Whether the text is stable across prompt types (file write vs command execution vs network), because one regex must cover every prompt that parks a soldier, or the ones it misses stay invisible.
3. Whether the prompt persists in `recent` after scrolling, which decides the `source` value.

Until all three are recorded, no pattern is configured. A pattern that matches nothing is indistinguishable from a working subscription, which is why guessing is worse than waiting.

## Pane process evidence (verified live 2026-07-29, herdr 0.7.5, protocol 17)

`herdr pane process-info --pane <id>` - note the flag form; the pane is NOT positional (`herdr pane process-info w48:p1` returns `unknown option`).

Returns `result.process_info` with `shell_pid` and `foreground_processes[]`, each carrying `pid`, `argv0`, `argv`, `cmdline`, and `cwd`. Sampled against two live soldier panes:

```text
w48:p1   agent process: 24722  codex
w49:p1   agent process: 42289  codex
```

This answers a question `agent get` cannot. `agent get` reports what herdr BELIEVES about a pane's agent; process-info reports what is actually running. An agent that exited leaves a pane whose `agent_status` reads idle or unknown - indistinguishable by status alone from an agent between turns. `cs_herdr_pane_agent_process` and `cs_herdr_pane_is_agent_husk` in `bin/cs-herdr-lib.sh` close that gap, and `bin/cs-crew-state.sh` reports a husk as `source: pane-process`.

**The husk predicate fails closed, deliberately.** "Could not read the process table" and "read it, no agent there" are different claims and only the second is a husk. Treating an unreadable answer as a husk would report a healthy soldier as dead on any herdr without process-info, on any transient socket error, and in every test stub. The `foreground_processes` array must be present before the predicate concludes anything. This was caught by an existing test rather than by review: the first implementation reported every stubbed pane as a dead agent.

## Pane presence: the answer is in the body, not the exit status (verified live 2026-08-02, herdr 0.7.5, protocol 17)

`herdr pane get <id> --session <s>` distinguishes three outcomes, and two of them share one exit status.

```text
$ herdr pane get w4K:p1 --session default          # live pane
{"result":{"pane":{ ... "pane_id":"w4K:p1" ... },"type":...}}     # STDOUT, rc 0

$ herdr pane get w9Z:p99 --session default         # absent pane
{"error":{"code":"pane_not_found","message":"pane w9Z:p99 not found"},"id":"cli:pane:get"}   # STDERR, rc 1

$ herdr pane get w4K:p1 --session no-such-lab-xyz  # server unreachable
Error: Os { code: 2, kind: NotFound, message: "No such file or directory" }                  # STDERR, rc 1
```

Two facts matter and neither is guessable:

- **The error body is on stderr.** A stdout-only read (`out=$(herdr pane get "$id" 2>/dev/null)`) captures nothing at all for an absent pane, so it cannot tell absence from an unreachable server. Both streams must be captured together.
- **The exit status cannot classify.** A confirmed-absent pane and an unreachable server are both rc 1. Only the structured body separates them: `.error.code == "pane_not_found"` is proof of death, any other error code is not, and non-JSON output is not an answer at all.

A malformed pane id is answered as `pane_not_found` too (`herdr pane get "not a pane"` returns that code), so herdr's answer is authoritative about the string it was asked, not about whether the string was well formed.

`cs_herdr_pane_presence` in `bin/cs-herdr-lib.sh` owns this classification and returns `dead|present|unknown`; a success body must echo the requested `pane_id` back to count as `present`, so a truncated or renamed-field response after a herdr upgrade degrades to `unknown` rather than to a wrong answer.

**Two readers, deliberately different.** `cs_herdr_pane_exists` stays exit-status-based and fails open, which is correct for callers that only want to skip work. Any caller about to destroy something on the strength of the answer must use `cs_herdr_pane_confirmed_gone`, which fails closed: `present` and `unknown` both refuse. `bin/cs-teardown.sh` gates record removal on it, so an unreachable herdr can never be read as "the soldier is gone". This is the same distinction the husk predicate above draws, applied to pane existence.

## One snapshot instead of N pane reads (verified live 2026-07-29, protocol 17)

`herdr api snapshot` returns every pane in one payload, each carrying `agent_status`, `agent`, `agent_session`, `cwd`, `tab_id`, `workspace_id`, `revision`, and `state_change_seq`. Sampled against the live session (23292 bytes, 10 panes):

```text
w48:p1   status=idle     agent=codex  state_change_seq=650
w49:p1   status=working  agent=codex  state_change_seq=674
w44:p1   ABSENT
```

`bin/cs-watch.sh` takes one snapshot per poll cycle (`snapshot_refresh`) and answers every pane status from it, so N panes cost one round-trip instead of N. Two rules make that safe:

- A pane ABSENT from the snapshot (like `w44:p1` above) is NOT a negative answer - it may have been created after the snapshot was taken - so it falls back to a direct query.
- A failed snapshot falls back to per-pane queries, which is exactly the pre-snapshot behavior.

The corroboration policy did not move: `cs_herdr_busy_state_from_raw` applies it to a raw status from either transport, so one owner covers both.

`state_change_seq` is `last_agent_state_change_seq` - it advances on agent STATE changes, not on terminal output (`src/app/actions.rs` increments it in the agent-state path). It is therefore a monotonic dedupe key for status transitions, NOT a replacement for output hashing. An early reading of this field as an output counter was wrong.

## Agent session identity and detection explain (verified live 2026-07-29)

`agent_session.value` is the agent instance's own session id, reported by herdr's official integrations (`herdr integration status` shows claude v7 and codex v6 installed here). Distinct per pane:

```text
w48:p1   session=019fac44-4d34-71f0-8da1-b916934c9b9a
w49:p1   session=019fae39-1f27-71b0-9557-840999f18487
```

This makes "did this soldier restart?" a fact rather than an inference: an unchanged id across a wedge proves the ORIGINAL instance is still there and no relaunch happened, while a changed id proves a different instance owns the pane. An absent id means no integration reported one, which is not an error and must not be read as a negative.

**Presence is less stable than "may be absent" suggests** (measured over a 7h soak, 210 samples, 26 distinct panes, 2026-07-30):

- Most agent panes reported a session in every single sample (210/210).
- `w48:p1`, a live codex soldier that HAD reported a session the previous afternoon, reported none in all 210 samples. Presence can be lost permanently while the agent keeps running, and both transports agree when it is (`agent get` and `api snapshot` both returned `codex/idle/none`), so this is the integration ceasing to report, not a snapshot defect.
- `w4B:p1` and `w4R:p1` flapped between present and absent within a few samples.

So absence is common and carries no information, which the recovery playbook already assumes. What is NOT yet established is whether a value that disappears and is later re-reported comes back IDENTICAL. Until that is measured, treat "changed id" as proof of a new instance only when both readings are present; a present -> absent -> present sequence is not a change, it is two observations with a gap. The soak that would have answered it recorded no usable timestamps on its per-pane rows, so the ordering was lost - a harness defect, not a herdr one.

`herdr agent explain <pane>` names the rule behind herdr's classification, e.g.:

```text
agent: codex
state: working
manifest: remote:.../agent-detection/remote/codex.toml 2026.07.18.1
rule: osc_title_working (region=osc_title priority=1050)
```

That matters because consigliere's busy-signature corroboration exists precisely because `agent get` alone was not trusted; `explain` turns a disagreement into a named rule instead of a guess.
