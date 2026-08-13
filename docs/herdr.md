# Herdr verified facts

Verified against herdr 0.7.4 (protocol 16) on 2026-07-22, re-verified against herdr 0.7.5 (protocol 17) on 2026-08-01, and re-verified again against herdr 0.8.0 (protocol 19) on 2026-08-12, all in isolated lab sessions.
The CI pin (`bin/cs-install-herdr.sh`) tracks 0.8.0 so the required herdr lane exercises the same CLI contract the fleet runs; it was 0.7.4 until an `agent wait` flag rename broke the fleet while CI stayed green - the exact drift shape this re-verification exists to prevent recurring.
Re-verify this table after any herdr upgrade; `bin/cs-bootstrap.sh` gates on the minimum protocol.
The 0.8.0 pass was source-and-CLI verified (herdr's own `Cargo.toml`, `src/api/schema/events.rs`, `src/detect/manifests/*.toml`, `herdr api schema --json`, `herdr --help` trees) rather than lab-session interactive, because that session's own launch permissions refused to start a nested claude/codex agent inside a nested herdr pane - two items below were recorded as blocked on that environment limit rather than guessed at.

**Both closed 2026-08-13, and the earlier block was two separate issues, not one.** First, this account's org policy forbids `--dangerously-skip-permissions` outright; `--permission-mode auto` (already `cs_harness_autonomy_flag`'s documented fallback, `bin/cs-harness-lib.sh`) launches cleanly instead and was not itself refused by the launch-permission classifier. Second, and separately, `cs_herdr_lab_raw` (`bin/cs-herdr-lab.sh`) unconditionally appended `--session <name>` after the caller's full argv; for `agent start ... -- AGENT_ARG...`, that landed the flag AFTER the subcommand's own `--` separator, so it became a literal trailing agent arg instead of herdr's own session selector and herdr resolved against the wrong session - the exact `agent_pane_not_found` this file's open items below were blocked on, mistaken at the time for a herdr-level quirk. Fixed by inserting `--session` before any trailing `--` (regression-pinned in `tests/cs-herdr-lab.test.sh`). Both fixes were needed together to launch a nested agent at all.

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
- `done` is not a fourth state layered on top of idle: herdr's own source maps `(Idle, seen=false) -> Done` and `(Idle, seen=true) -> Idle` (`src/app/api_helpers.rs`, herdr source, verified 2026-08-12) - "done" means the agent went idle and the pane has not been read since.

### Blocked detection covers claude/codex permission prompts natively (verified against herdr source, 2026-08-12)

Herdr's own detection manifests carry `state = "blocked"` rules that fire on the exact permission-prompt text this fleet cares about, not just on generic "waiting on a human" text:

- claude (`src/detect/manifests/claude.toml`, herdr source): `bash_permission_prompt` (matches "do you want to proceed?" plus bash markers and a yes/no option list), `generic_permission_prompt` ("do you want to proceed?" + "esc to cancel" after the last horizontal rule), `live_blocked_form` ("esc to cancel" + an enter/navigate combination), `legacy_no_prompt_blocker` ("waiting for permission", "tab to amend", "would you like to"...).
- codex (`src/detect/manifests/codex.toml`, herdr source): `osc_title_blocked` (OSC title "Action Required"), `trust_directory` (the folder-trust dialog), `live_strong_blocker` ("allow command?").
- Manifests update over herdr's own remote channel independent of the CLI version (`agent explain` reports a `manifest: remote:...` line with its own date-stamped version).

This is solved by the substrate rather than by a hand-captured `pane.output_matched` pattern: `pane.agent_status_changed` subscriptions accept an optional `agent_status` filter (`src/api/schema/events.rs`, herdr source) so a supervisor can subscribe to just the statuses it acts on with zero pattern maintenance and no dependency on capturing the exact rendered prompt text.
**Adopted 2026-08-13:** `bin/cs-herdr-events.py` subscribes `pane.agent_status_changed` TWICE per pane, once with `"agent_status":"blocked"` and once with `"agent_status":"working"` (`pane.exited`/`pane.agent_detected` stay unfiltered).
Two separate live verifications back this, and they cover different things, so they are recorded separately rather than merged into one claim.

**Evidence 1 - native blocked classification and filtered delivery (2026-08-13, herdr 0.8.0/protocol 19, isolated `cs-herdr-lab.sh` sessions, never the default session).**
This body of evidence was captured against the BLOCKED-ONLY subscription shape that shipped first, so it establishes native classification and blocked-filter delivery, not the two-filter shape.
A real nested claude agent (`herdr agent start ... --kind claude`) produced three independent genuine blocked transitions across two labs:
- The one-time folder-trust dialog on first launch: "Quick safety check: Is this a project you created or one you trust?".
- A Bash-tool prompt under `--permission-mode default` in a directory with a cached per-command approval from a prior run, which cleared before a second `pane read` could catch its rendered text (only the status field was caught blocked that time).
- A clean, fully-captured `bash_permission_prompt` rule match in a fresh untrusted directory: prompted `Use the Bash tool to run exactly: curl -s -o /dev/null -w "%{http_code}" https://example.com`, `pane read` showed `This command requires approval / Do you want to proceed? / 1. Yes  2. Yes, and don't ask again for: curl *  3. No / Esc to cancel · Tab to amend · ctrl+e to explain` verbatim, matching the manifest's own "do you want to proceed?" + yes/no list.
The first two both happened in the FIRST lab, the only one with `bin/cs-herdr-events.py` attached, and each arrived as the ordinary `status\t<pane>\t<ws>\tblocked\tclaude` projected line, decoded identically to the pre-filter unfiltered stream.
The third happened in the SECOND lab, which had no reader attached and was observed only through direct `agent get`/`pane read` polling, so it independently corroborates the manifest match rather than re-proving push delivery.
That single reader lab attached one blocked-only filter to a pane that was IDLE at subscribe time, and `@subscribed` plus exactly one such line was the reader's full captured output for each of its two transitions - Evidence 2 shows that is a property of the pane's state at subscribe time, not a general rule.
The poll-path fallback is unchanged and stays the permanent backstop (`cs-watch.sh`'s poll pass reads `pane_busy_state` every cycle regardless of push capability) - this verification only closes the "does the filter actually deliver" open item, per data/stow-synthesis-survey/report.md S2.

**Evidence 2 - the two-filter subscribe shape itself (probed 2026-08-13, herdr 0.8.0/protocol 19, isolated `cs-herdr-lab.sh` session `cs-lab-s2probe`, since torn down).**
A real nested claude agent launched with `--permission-mode default` in a fresh untrusted directory was observed through a throwaway raw AF_UNIX client that sent exactly two subscriptions for one pane, `agent_status` `blocked` followed by `agent_status` `working`.

- Two same-type, same-pane subscriptions carrying DIFFERENT `agent_status` filters are accepted: the server returned a single `subscription_started` result, with no dedupe and no rejection, and both filters went on to deliver.
- Subscribing while the pane was IDLE produced no initial event, and the connection stayed silent until real transitions occurred.
- Prompting a bash command that needs approval then delivered both edges in the correct order on that same connection: the working edge about 3.7s after subscribe, and the blocked edge about 7.0s after subscribe.
- Subscribing fresh to a pane ALREADY blocked emitted an immediate initial blocked event, about 1ms after the acknowledgement.
- Subscribing fresh to a pane ALREADY working emitted an immediate initial working event, about 1ms after the acknowledgement.

The last two observations correct a claim this section previously stated as general: the server emits an initial event for a pane already in a state the subscription matches, so a reader attaching to an already-blocked or already-working pane immediately receives one extra line for that current state.
"`@subscribed` plus exactly one line" therefore holds only for a pane that is idle at subscribe time.
That initial-event behavior is largely not a new capability for this supervisor: `cs_watch_wait_transition` already walks the panes on every reconnect, reading each pane's status and routing it through `cs_transition_apply` until it finds an actionable one, which clears the per-pane escalation dedupe marker on `working` before the stream is drained at all.
That walk is not guaranteed to sample every pane on a given reconnect: it stops at the first actionable pane and skips any pane whose status read comes back empty, so a later pane's stale marker can survive that reconnect.
The initial event therefore delivers the same clear through the stream, agreeing with the reconcile where the reconcile reached, and still carrying real value for the panes it did not reach.
The level reconcile stays the path that works when the socket delivers nothing.

Two filters rather than one, because exactly two statuses are edge-triggered work for `bin/cs-watch.sh`'s `cs_transition_policy`: `blocked` is actionable (the wake) and `working` is absorb (it clears the pane's `.herdr-escalated-<pane>` dedupe marker so the NEXT `->blocked` edge re-escalates instead of being suppressed).
`working` cannot be dropped in favor of the poll pass: the poll pass and the reconnect level-reconcile both sample pane state once per `POLL` cycle (15s), so a working window that opens and closes inside a single drain window - approve a permission prompt, the agent runs one quick command, it blocks again - is never observed by either, the stale marker suppresses the second blocked push, and escalation silently degrades from an instant push wake to the hash-stale cadence.
The pushed `working` edge is the only observer of that window, so it stays on the wire.
`idle` and `done` ARE safe to drop: both are `defer`, a pure no-op on the fast path.
So the two filters keep `idle` and `done` edges off the wire while retaining the `blocked` and `working` edges the transition policy acts on.

Known limitation, accepted for this round rather than fixed: herdr polls each active subscription in request order and returns at most one event per subscription per ~100ms connection cycle (`src/api/server.rs`, `src/api/subscriptions.rs`, herdr source), so a `working` edge and a `blocked` edge that land inside the SAME cycle can be delivered blocked-first.
When that happens the already-set marker suppresses that blocked wake and the `working` edge then clears the marker, so the fast-path wake is missed for that one pair and the case self-heals through the ordinary poll pass within `POLL` (15s).
That is strictly narrower than the pre-fix behavior, where the `working` clear never arrived by push at all.
This ordering detail is reviewed herdr SOURCE behavior, not a live-verified fact: that subscription polling follows request order was NOT independently probe-verified here.
Tradeoff to remember before scaling watched pane counts: two status subscriptions per pane means herdr performs roughly twice the per-cycle pane probing for status that one subscription would.
- `agent wait <pane> --until <status> --timeout <ms>` blocks until the status is reached (verified ~5s wait resolving on turn end); use it for submit confirmation and bounded single-target waits.
  **The flag was RENAMED between releases: 0.7.4 took `--status`, 0.7.5 takes `--until`, and each rejects the other outright.**

  ```text
  $ herdr agent wait bogus999 --status idle --timeout 200   # on 0.7.5
  unknown option: --status
  rc=2
  ```

  This is the only recorded case of a herdr CLI contract moving under a running fleet, and it cost real supervision: consigliere shipped `--status` (correct for 0.7.4, recorded verified here), herdr self-updated the boss's machine to 0.7.5, and because `cs_herdr_submit_confirm` discards both streams the usage error read as "the turn never started" - every steer burned its Enter-retry loop and reported "not confirmed" even on success, and the away daemon's strict undelivered path stayed on. CI pinned 0.7.4 and never saw it.
  Guarded three ways now: the CI pin tracks the currently-running release (0.8.0 as of 2026-08-12, previously 0.7.5), `tests/cs-herdr-lib-live.test.sh` asserts the current spelling works AND that `--status` is rejected, and the offline fakes reject `--status` too, because a fake that matched only the subcommand is what let it ship.

- Known upstream gap (firstmate evidence, docs/herdr-backend.md): `agent get` can read `idle` during a LONG foreground tool call. Policy: native `working` is trusted outright; native `idle`/`unknown` must be corroborated against the codex busy signature (`esc to interrupt`) before a soldier is declared not-working. Single constant in `cs-herdr-lib.sh`.

## Capture

- `pane read <pane> --lines N --format text|ansi` returned exactly N lines on 0.7.4; the upstream small-`--lines` truncation bug was NOT reproduced. `cs-herdr-lib.sh` passes `--lines` through directly; if a regression appears, re-add the read-wide-then-tail workaround from firstmate's adapter.
- `pane run <pane> '<text>'` submits text plus Enter atomically (verified launching codex and steering it).
  It reports success whether or not the pane's SHELL was ready to read the line. A freshly created worktree pane frequently is not, and the line is then lost with no way to recover it from the buffer - `tests/cs-herdr-lib-live.test.sh` works around this by re-submitting an idempotent probe, and `bin/cs-spawn.sh` guards against it by requiring an agent to actually appear afterwards (`cs_herdr_agent_wait_present`). Never treat a `pane run` exit status as proof the command ran.
- Machine input uses U+2063 INVISIBLE SEPARATOR because it survives UTF-8 terminal input; the upstream herdr 0.7.3 incident showed ASCII 0x1f was stripped from the composer. `bin/cs-operational-input.sh` owns the exact bytes.

## Keys and pane working directory (verified live 2026-08-11, herdr 0.7.5)

`pane send-keys` accepts a NARROW key vocabulary, and an unsupported name is refused with a structured error rather than approximated:

```text
$ herdr pane send-keys w1:p1 C-u --session cs-lab-ctl2
{"error":{"code":"invalid_key","message":"unsupported key C-u"},"id":"cli:request"}

$ herdr pane send-keys --help
Use esc as the canonical Escape key name; escape is also accepted.
```

Consequence for the agent-control plane: there is no way to CLEAR a composer through herdr, so `bin/cs-control-lib.sh` gets past unsent text by SUBMITTING it - one flush Enter, cancel the turn that starts, then type the exit command regardless of what the classifier still says, with the verified postcondition deciding the outcome (docs/agent-control.md).

**Correction (herdr source, verified 2026-08-12): the probe above tested the wrong spelling, not a real capability gap.** `parse_api_key` aliases only `C-c` -> `ctrl+c` (and `+` -> `plus`) before delegating to herdr's full keybinding combo parser (`src/app/api_helpers.rs` -> `src/config/keybinds.rs`, herdr source), which accepts `ctrl|control|shift|alt|option|meta|cmd|command|super|hyper` combined with any named key. `C-u` was never going to parse - it isn't one of the two aliases - but `ctrl+u` is, and has been since v0.7.0 (`git tag --contains` on the commit that added combo-syntax support spans v0.7.0 through the current 0.8.0). Whether `ctrl+u` actually CLEARS a given agent's composer is agent behavior, not a herdr-CLI question, and remains an open item:

**Resolved for claude (verified live 2026-08-13, claude 2.1.x, isolated herdr lab): `ctrl+u` DOES clear a claude composer, but one press kills back to the start of the CURRENT VISUAL (wrapped) row only, not the whole buffer.** Typed text that fits on one row clears in a single `ctrl+u`. Text long enough to wrap across N visual rows needs N presses - one per wrapped row - confirmed by typing a two-row-wrapping string, sending one `ctrl+u` (only the second/last row cleared, first row remained), then a second `ctrl+u` (composer went fully empty, bare `❯`). A caller that assumes one press always empties the composer is wrong for anything long enough to wrap; `bin/cs-control-lib.sh`'s flush-by-submitting design is NOT revised on the strength of this alone - a multi-press clear loop still needs its own postcondition-verified design, and codex remains untested. Run the codex side before touching that file.

`pane get` reports the pane's own working directory beside the foreground process's, both physically resolved:

```text
$ herdr pane get w1:p1 --session cs-lab-ctlcodex
{"id":"cli:pane:get","result":{"pane":{"agent_status":"unknown",
 "cwd":"/private/var/folders/.../ctlcodex.SshnGI/repo",
 "foreground_cwd":"/private/var/folders/.../ctlcodex.SshnGI/repo",
 "pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1", ...}}}
```

`cs_herdr_pane_cwd` reads `result.pane.cwd`. Because herdr resolves the path (`/private/var/...` for a `/var/...` symlink on macOS), any comparison against a recorded path must resolve that path too; `cs_control_pane_in_dir` does, and reports "cannot tell" separately from "does not match".

## Push events

- Multi-pane push (`events.subscribe` -> `pane.agent_status_changed`) is socket-only; no CLI subcommand.
- `bin/cs-herdr-events.py` is the raw AF_UNIX subscriber (ported from firstmate's herdr-eventwait.py); the watcher splices it in when the socket is capable and keeps the poll loop as the permanent backstop.
- `pane.agent_status_changed` accepts an optional `agent_status` filter in the subscription request itself (`src/api/schema/events.rs`, herdr source, verified 2026-08-12) - a supervisor can subscribe to blocked-only (or any single-status) transitions per pane instead of receiving and locally triaging every transition. **Adopted 2026-08-13**: `bin/cs-herdr-events.py` subscribes twice per pane, `agent_status:blocked` (wake) and `agent_status:working` (dedupe-marker clear), dropping only `idle`/`done`; see "Blocked detection covers claude/codex permission prompts natively" above for the live end-to-end verification.

## Known gaps / watch list

- `worktree create` fails (`worktree_create_failed`) when the target directory `~/.herdr/worktrees/<repo_name>/<branch-sanitized>` already exists - e.g. leftovers from an aborted task whose repo clone is gone. cs-spawn must treat that as stop-and-report (a leftover directory may hold unlanded work); never pre-delete the path to make the create succeed.

- No `workspace move` CLI (method exists in `api schema`); consigliere does not order workspaces, so no shim is ported.
- Tab labels are not unique; list-live matching stays defensive (scope to this home's workspace ids from meta, never by label sweep).
- `herdr integration install codex` / `claude` are BOTH installed on this machine already (`herdr integration status`: claude current v7, codex current v7) - herdr installs them itself when it detects the binary, not something consigliere opted into. Corrected 2026-08-12: this line previously read "not used yet", which was wrong. What v7 actually does (herdr source, `src/integration/claude_settings.rs`): register exactly one `SessionStart` hook that reports session id + transcript path for native resume (below); it does NOT report turn ends - earlier integration versions registered `Stop`/`PermissionRequest`/`PreToolUse` lifecycle hooks and v7 explicitly REMOVES them, because lifecycle state now comes entirely from the screen-detection manifests. Consigliere's own Stop-hook turn-end wiring (`bin/cs-turnend-guard.sh`) is therefore not duplicated by anything herdr installs; codex is still launched directly with explicit flags so the launch template stays under consigliere's control.
- Herdr persists `agent_session_id` per pane (below) and, on server restart, rebuilds and re-executes each agent's resume command itself (`claude --resume <id>`, `codex resume <id>`, `src/agent_resume.rs`, herdr source) - including on a headless server with no TUI attached. This is a native answer to the server-restart half of `bin/cs-spawn.sh --relaunch`'s job; the live-server agent-died-mid-task half that relaunch also covers has no herdr-native equivalent and keeps its own pid-proof design (see `docs/agent-control.md`).

## Push event subscriptions (verified live 2026-07-29 at herdr 0.7.5/protocol 17; re-verified live 2026-08-12 at herdr 0.8.0/protocol 19)

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

The rejection is the authoritative capability list, because the server enumerates what it will accept.
At protocol 17 (2026-07-29):

```text
workspace.created workspace.updated workspace.metadata_updated workspace.renamed
workspace.moved workspace.closed workspace.focused worktree.created
worktree.opened worktree.removed tab.created tab.closed tab.focused tab.renamed
tab.moved pane.created pane.closed pane.updated pane.focused pane.moved
pane.exited pane.agent_detected pane.output_matched pane.agent_status_changed
pane.scroll_changed layout.updated
```

At protocol 19 (2026-08-12, same probe technique against a fresh `cs-lab-*` session, real socket, real pane), the ONLY change is one addition, `workspace.reordered`, inserted right after `workspace.moved`:

```text
$ python3 -c '... events.subscribe {"type":"pane.bogus_kind_probe"} ...'
{"id":"","error":{"code":"invalid_request","message":"invalid request: unknown variant `pane.bogus_kind_probe`, expected one of `workspace.created`, `workspace.updated`, `workspace.metadata_updated`, `workspace.renamed`, `workspace.moved`, `workspace.reordered`, `workspace.closed`, ... [rest identical to the protocol-17 list above] ..."}}
```

`workspace.reordered` is irrelevant to consigliere today (it does not order workspaces, per "Known gaps" below) but is recorded here because this section's whole point is the server's own enumeration, not an assumption that nothing changed.

- `pane.output_changed` is a real internal event kind but is NOT subscribable at protocol 19 either. Source reading alone is misleading here: the exclusion list in `src/api/schema/events.rs` governs plugin hooks, not subscriptions. Probe the socket, do not infer from the source.
- `pane.output_matched` REQUIRES a `source` field (`visible`, `recent`, or `recent-unwrapped`); omitting it is `invalid_request`, not a default.
- `pane.agent_status_changed` accepts an optional `agent_status` filter in the same subscription object - live-verified 2026-08-12 against a real pane in a fresh lab: `{"type":"pane.agent_status_changed","pane_id":"w1:p1","agent_status":"blocked"}` returned `{"result":{"type":"subscription_started"}}`. Delivery of a real filtered transition, and acceptance of two same-pane subscriptions carrying different `agent_status` filters, were both live-verified 2026-08-13 against a real nested claude agent - see "Blocked detection covers claude/codex permission prompts natively" above for the recorded observations.
- `bin/cs-herdr-events.py` subscribes to `pane.agent_status_changed` TWICE per pane, filtered to `agent_status` `blocked` and `agent_status` `working`, plus unfiltered `pane.exited` and `pane.agent_detected`, plus `pane.output_matched` for each pattern in `CS_HERDR_EVENT_PATTERNS`.

### Protocol precondition

`CS_HERDR_MIN_PROTOCOL` in `bin/cs-herdr-lib.sh` is the floor (16); the live server reports 19 as of 2026-08-12 (herdr 0.8.0).
The herdr source checkout at `~/github/oss/herdr` HEAD already declares `PROTOCOL_VERSION = 20` (`src/protocol/wire.rs`) - that is unreleased work ahead of the installed 0.8.0 binary, not a live-verifiable fact yet; re-probe again once a released herdr reports 20.

Every capability above was verified at protocol 17 or 19 only, because those are the servers that were actually running when each pass happened. They are NOT verified at 16 or 18, and this repo has no protocol-16 or protocol-18 server to test against. So the floor deliberately stays at 16 and each new capability is gated at runtime instead of by version arithmetic: the subscribe either returns `subscription_started` or it does not, and `bin/cs-watch.sh` already treats any reader failure as "fall back to polling for this cycle". Raising the floor would trade a working fallback for a hard refusal, and would do it on an unverified assumption about which protocol first carried each event.

Re-probe after a herdr upgrade rather than trusting this table.

### `pane.output_matched` pattern caution (the old "Pattern policy trap" plan is retired - see "Blocked detection..." above)

A configured `pane.output_matched` pattern means "wake the supervisor". Do not configure a benign high-volume pattern: the harness busy signature (`CS_HARNESS_BUSY_RE`, `[Ee]sc to interrupt`) renders continuously during every turn, so subscribing to it would fire an actionable wake on every frame of normal work.
This still stands for any future `pane.output_matched` use; the claude/codex permission-prompt case itself no longer needs a captured pattern at all (native `blocked` detection, adopted and live-verified above), so no text-pattern capture should be added for it.

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

Re-measured in an isolated lab on 2026-08-11 while building the agent-control plane, and the two harnesses did not behave alike:

```text
codex 0.147.0, fresh agent, one completed turn:  agent_session.value ABSENT
claude 2.1.227, fresh agent:                     62f6021c-f1da-4edb-8701-671b8e665c8f
claude after /exit + `claude --continue`:         62f6021c-f1da-4edb-8701-671b8e665c8f (UNCHANGED)
```

Two consequences for relaunch. A codex soldier reports no session id at all, so an id comparison there is a no-op that looks like evidence. And a RESUME legitimately keeps the same id, because resuming continues the same session, so "unchanged id" is proof of a failed relaunch only for a COLD launch. The identity proof that holds on both harnesses and both launch paths is the agent PROCESS: `cs_control_agent_pid` before and after, which is why `bin/cs-control.sh` decides on the pid and reports the session id as corroboration.

So absence is common and carries no information, which the recovery playbook already assumes. What is NOT yet established is whether a value that disappears and is later re-reported comes back IDENTICAL. Until that is measured, treat "changed id" as proof of a new instance only when both readings are present; a present -> absent -> present sequence is not a change, it is two observations with a gap. The soak that would have answered it recorded no usable timestamps on its per-pane rows, so the ordering was lost - a harness defect, not a herdr one.

`herdr agent explain <pane>` names the rule behind herdr's classification, e.g.:

```text
agent: codex
state: working
manifest: remote:.../agent-detection/remote/codex.toml 2026.07.18.1
rule: osc_title_working (region=osc_title priority=1050)
```

That matters because consigliere's busy-signature corroboration exists precisely because `agent get` alone was not trusted; `explain` turns a disagreement into a named rule instead of a guess.

## New at 0.8.0: an agent-automation facade consigliere is only partly using (source-verified 2026-08-12; CLI shapes confirmed against the installed 0.8.0 binary's `--help`)

Most of the below is not adopted yet - recorded here as available capability so the next change to `bin/cs-herdr-lib.sh`, `bin/cs-spawn.sh`, or `bin/cs-control-lib.sh` starts from what herdr can already do, not from a re-derivation of the current workarounds.

- **`herdr agent prompt <target> <text> [--wait] [--until <status>]... [--timeout MS]`** - atomic bracketed-paste submit with an optional server-owned wait; without `--timeout` the wait is indefinite, and a submission that never observes a state change within 5000ms returns a distinct `agent_prompt_stalled` error rather than a false "confirmed" (herdr source, `src/cli/agent.rs`). **Adopted**: `cs_herdr_agent_prompt_confirmed` (`bin/cs-herdr-lib.sh`) calls `agent prompt ... --wait --until working`, and `cs_prompt_guarded` (`bin/cs-prompt-lib.sh`) is now the sole caller, collapsing what used to be a plain `agent prompt` submit plus a separate `cs_herdr_submit_confirm` poll into the one native call. `bin/cs-send.sh` submits via plain `pane run`, not `agent prompt`, so it has no equivalent single-call collapse and keeps calling `cs_herdr_submit_confirm` directly.
- **`herdr agent start <name> --kind <claude|codex|...> --pane <id> [--timeout MS]`** - launches into an existing pane and polls until `interactive_ready`, failing distinctly on `agent_not_ready`, `agent_kind_mismatch`, or `agent_start_failed` (herdr source, `src/cli/agent.rs`). This is a native version of what `cs_herdr_agent_wait_present`'s launch-then-poll guard hand-builds today, with a richer failure vocabulary than "present or not yet".
- **`herdr agent wait <target> [--until <status>]...`** - `--until` is now repeatable (wait for idle OR done OR blocked in one call); without `--until` it already matches idle, done, or blocked by default (`herdr agent wait --help`, installed 0.8.0 binary).
- **`herdr pane wait-output <pane_id> (--match TEXT | --regex PATTERN) [--source ...] [--timeout MS]`** - a CLI-level blocking wait for pane output, no socket subscriber required for a one-shot pattern wait.
- **`herdr notification show <title> [--body TEXT] [--sound none|done|request]`** - a native toast/sound channel from the CLI, a candidate replacement for part of `bin/cs-prompt-lib.sh`'s hand-rolled osascript/herdr/command wedge-alarm channel plumbing.
- **Named agents.** `agent rename` lets a supervisor address a pane by name (e.g. the task id) instead of tracking pane ids; the name clears when the occupant exits.
- **Server-side exec-on-event.** A herdr plugin manifest may declare `[[events]] on = "pane.agent_status_changed" command = [...]` (high-volume kinds like `pane.output_changed`/`layout.updated` are deliberately excluded from the allowed set) plus one-shot `[[startup]]` hooks (herdr source, `src/app/api/plugins/mod.rs`). This runs server-side and survives a supervisor restart, unlike `bin/cs-herdr-events.py`'s subprocess-per-watcher-run design.
- **Offline detection testing.** `herdr agent explain --file <capture> --agent <label> [--verbose]` runs the manifest engine against a saved capture instead of a live pane, and a new `--source detection` read (`pane read`/`agent read`) returns exactly the text region the classifier evaluates. Useful for turning a busy-signature regression into a named-rule assertion instead of a byte-for-byte pane capture pin.
- **Misc fields available on reads already in use**: `AgentInfo.launch_pending`/`interactive_ready` on `api snapshot`; `pane report-agent`/`report-metadata --state-label --token --ttl-ms` let a supervisor stamp its own display-only state onto a pane under a non-reserved source id.
- **Correction (verified live 2026-08-13): `PaneReadResult.truncated` is NOT reachable through `herdr pane read`.** The field exists in the socket API's `PaneReadResult` schema, but the CLI's own `print_read_response` (herdr source, `src/cli.rs:61-70`) extracts and prints only `result.read.text`, for every `--format`/`--source` combination - there is no flag that returns the JSON envelope carrying `truncated`. A truncated read is invisible to any caller going through the CLI, including `cs_herdr_capture`; only a direct socket client could see it.

None of the above changes the corroboration policy at the top of this file; that policy is about whether a native `idle`/`unknown` reading can be trusted, and nothing here re-verifies that specific claim (see the open item below).

## Verified: does native idle still misread during a long foreground tool call at 0.8.0? (verified live 2026-08-13, claude 2.1.x, isolated herdr lab)

The corroboration policy (`cs_herdr_busy_state_from_raw`, `bin/cs-herdr-lib.sh`) exists because `agent get` could read `idle` while an agent was genuinely mid-turn inside a long foreground tool call.
Probe: a live claude agent was told to run the Bash tool exactly once, foreground, `sleep 20`, with the Monitor tool and any background flag explicitly forbidden; `agent get`'s `agent_status` was sampled every second against a shared clock, correlated against the pane transcript's own `⏺ Bash(sleep 20` tool-call line so the sampled window is known to bracket the real call, not guessed at.

Result: `agent_status` read `working` continuously for the entire ~24-25s the tool call was genuinely in flight (the sleep plus the agent's own pre/post-call reasoning), with no `idle`/`unknown` blip in the middle, and correctly flipped to `idle` only once the call had actually finished and the agent returned to its composer.
No misread reproduced in this scenario.

This is one clean sample of one command shape (a plain `sleep`, which renders nothing to the screen) on one harness (claude), not exhaustive proof the misread can never happen - a command that repaints the screen mid-run, a much longer call, or codex's own detection manifest could still behave differently.
The corroboration policy stays exactly as documented above on that basis: this is a positive data point toward eventually relaxing it, not grounds to remove or shrink it yet.
