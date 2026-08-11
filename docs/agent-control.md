# Agent lifecycle control plane

Consigliere talks to a running soldier two ways, and they are not the same channel.

The **data plane** is [`bin/cs-send.sh`](../bin/cs-send.sh): conversational text for the agent to read.
For a `kind=capo` target it always carries the from-consigliere routing marker, because a capo is itself a consigliere and its reply must come back through the status path rather than a chat nobody reads.

The **control plane** is [`bin/cs-control.sh`](../bin/cs-control.sh): allowlisted lifecycle verbs addressed to an exact task id.

The split exists because the data plane's marking is exactly right for a message and exactly wrong for a lifecycle command.
A routing-marked exit command arrives as ordinary chat, which the agent reasons about instead of executing.
Worse, the workaround lived only in agent prose - remember to send an unmarked line, remember which key this harness cancels with, remember the resume shape and re-type the launch flags by hand - so it failed again every time a session did not happen to recall it.

## What the control plane owns

[`bin/cs-control-lib.sh`](../bin/cs-control-lib.sh) is the shared, side-effect-free half: the verb allowlist, the endpoint predicates, the two verb implementations with their postconditions, and the relaunch journal's paths and phase rule.
`bin/cs-control.sh` is the CLI and the relaunch transaction; `bin/cs-spawn.sh --relaunch` is the launch owner.
Per-harness mechanics are NOT duplicated here: the interrupt key, the exit command, the pre-Enter settle, the resume command, and the relaunch launch string all come from [`bin/cs-harness-lib.sh`](../bin/cs-harness-lib.sh), the single owner of every per-harness fact, and the endpoint mechanics from [`bin/cs-herdr-lib.sh`](../bin/cs-herdr-lib.sh).
There is no backend matrix to consult: consigliere has one runtime (herdr) and two harnesses (codex, claude), and the empirical basis for each value is the verification record in [`docs/codex.md`](codex.md), [`docs/claude.md`](claude.md), and [`docs/herdr.md`](herdr.md).

## Verbs

| Verb | Effect | Postcondition |
| --- | --- | --- |
| `interrupt` | Deliver the harness's interrupt key (Escape on both) and leave the agent running. | The turn is no longer running and the agent's PROCESS is still on the pane - process evidence, not herdr's belief, because an exited agent can leave a stale idle status behind (docs/herdr.md). Already idle and a delivered stop are claimed only with that evidence plus a positively observed idle or done reading: a husk pane reports `agent-gone`, and a state that cannot be corroborated either way - before the key, during the wait, or at its end - reports `state-unknown`, a failure rather than an idle, stopped, or still-running agent. |
| `exit` | Stop the agent, preserving the pane, its shell, the worktree, and every uncommitted change. Unsent composer text is flushed first (see below). | The pane is POSITIVELY agent-free: its process table was read and holds no agent process. Already gone is idempotent success. |
| `relaunch` | Replace the running agent with a new one in the same pane and worktree, on the recorded profile or an explicitly chosen model and effort. | An agent is alive on the recorded pane under a DIFFERENT process than the one that was stopped. |

The interrupt key is delivered exactly once.
Codex reads a second Escape at an idle composer as "edit the previous message", so an unconfirmed interrupt is reported rather than mashed.

An agent taking a turn does not execute a composer command - it queues the text as input - so `exit` interrupts first when the target is mid-turn.
That is part of stopping, not a separate courtesy, and a turn that will not cancel is reported as `exit-not-attempted` rather than followed by a command that would be swallowed.

An interrupt is not complete until the composer is clear, and herdr cannot clear one: `pane send-keys` refuses `C-u` outright, and a second interrupt key does not clear it either (docs/herdr.md, docs/claude.md).
Unsent composer text is a measured failure, not a hypothetical: a steer that arrives mid-turn is queued into the composer, and typing the exit command onto it submits both as one prompt the agent then reasons about instead of exiting.
So the only way past it is to SUBMIT the line, and `exit` does exactly that once - one Enter, then cancel whatever turn that starts - because the content is almost always consigliere's own queued steer and the next step stops the agent anyway.
After that one flush the command is typed regardless of what the classifier still says.
Two measured reasons: text that survives an Enter is not unsent input, and the classifier reports `pending` for rows that only LOOK like a composer - a real soldier pane reads `pending` off its own shell prompt row before the agent has drawn its UI, because the shell prompt glyph and claude's composer glyph are the same character (docs/claude.md).
Refusing on that reading blocked the verb on healthy soldiers, and a blocked recovery is worse than one wasted prompt: an unverified exit is reported honestly and a retry finds the composer empty.

**Teardown and discard are not verbs and will not become verbs.**
`exit` stops an agent and preserves everything else.
Removing a worktree, closing a pane, deleting a branch, or discarding work stays with [`bin/cs-teardown.sh`](../bin/cs-teardown.sh), which owns the landed-work proofs.

**`resume` is not a verb either.**
It is the preferred half of `relaunch`, not a separate command: relaunch resumes when a session is resumable and cold-launches from the brief when it is not, so the caller never has to know which case it is in.

## Transactional relaunch

`relaunch` is the only verb that changes durable records, so it runs as a transaction with a journal at `state/<id>.control-relaunch` (flat `key=value`, last occurrence wins, read and written through `bin/cs-meta-lib.sh`; `bin/cs-control.sh --help` owns the field list).

1. **Validate everything.** The target must be a recorded ordinary direct report in THIS home with a positively present pane, a worktree that is its own git root, a brief on disk, a usable effort level, and a one-line `--note`. A `kind=capo` and a headless scout are refused by name.
2. **Journal the checkpoint.** Phase `prepared` records the endpoint, the profile before and after, the agent pid and session id that were running, and the work being preserved: the worktree's HEAD and its uncommitted-file count.
3. **Record the note.** The note is appended to `data/<id>/brief.md` atomically (write, rename), because the replacement inherits the local copy and none of the conversation. A cold launch therefore reads it as part of its instructions, and a relaunch that fails later still leaves it for the next recovery.
4. **Stop the old agent** through the `exit` verb, with its postcondition.
5. **Launch the replacement** through its single owner, `bin/cs-spawn.sh --relaunch`, which adopts the recorded endpoint and worktree instead of creating either.
6. **Verify and report.** A different agent process must own the pane. On a cold launch an unchanged agent session id is also proof of failure; on a resume the same id is expected, because resuming continues the same session. After a resume the note is steered in through `bin/cs-send.sh`, since a resumed session does not re-read its brief.

Resume-first is what makes a relaunch cheap: both harnesses key sessions by working directory and every soldier owns a unique worktree cwd, so resuming from that worktree recovers exactly that soldier's own session with its context intact.
`bin/cs-spawn.sh --relaunch` waits for the resumed agent, breaking out early the moment the pane is positively agent-free again - which is precisely what a harness with nothing to resume leaves behind (`No conversation found to continue`, rc 1).
Only then does it deliver the cold launch, so a slow resume can never end up with two agents in one pane.
A detected agent is not immediately believed either: a harness that has nothing to resume still RUNS for a second before printing its refusal, and herdr's detector sees an agent in that window, so a launch counts only once the agent is still there after a settle AND its process is readable on the pane.
That is the same evidence the transaction verifies afterwards, so the launch owner and its caller cannot disagree about whether an agent came up.

### Failure and rollback

- A refusal **before** the agent is stopped leaves this home's records and the soldier's instructions byte-identical: nothing is written until every validation has passed.
- A stop that cannot be confirmed leaves the agent running, reports the concrete obstacle, and marks the journal `failed:stopping`.
- A launch failure **after** the stop reports plainly that no replacement agent was confirmed and where the work is preserved (worktree, commit, uncommitted count), and marks the journal `failed:launching`. The recorded profile is left describing what the task was dispatched on, because no replacement was confirmed to describe.
- A journal left in a non-terminal phase means the process running the transaction died mid-flight. The next relaunch REFUSES, prints the journal and the live pane state, and requires `--clear-journal` to acknowledge it. That is the difference between reporting a half-finished transaction and launching a second agent into the same pane.

## Fail-closed boundaries

- **Targeting is exact.** Only a bare task id with a `state/<id>.meta` record in this home is accepted. There is no pane-id form, no label search, and `CS_HOME` must be explicit, the same rule `bin/cs-send.sh` fails closed on.
- **An unconfirmed endpoint refuses.** `dead` and `unknown` are different answers (docs/herdr.md): a pane herdr cannot positively confirm is never acted on.
- **"The agent stopped" needs positive evidence.** An unreadable process table is not proof of absence, so `cs_control_agent_gone` fails closed and `exit` reports `still-running` rather than guessing.
- **A natively blocked agent is reported, never keyed past.** `blocked` means the pane is waiting on a human, and a harness dialog answers keystrokes as CHOICES: codex's directory-trust prompt (`1. Yes, continue / 2. No, quit`, docs/codex.md) would read an Enter as consent. So `interrupt` reports it, and `exit` withholds its command wherever the blocked reading appears - at an attempt's entry, after the composer flush, or between its two attempts - reporting `blocked` instead of delivering a key. That pane is recovered by replacing the endpoint - close it and reopen the surviving worktree - which the `stuck-soldier-recovery` skill owns.
- **A capo is refused for `exit` and `relaunch`.** A capo is a persistent home with its own state, backlog, and child tree; the `capo-provisioning` skill owns that lifecycle. `interrupt` is allowed, because cancelling a turn changes nothing durable.
- **A headless scout is refused for every verb.** It is a plain `codex exec` / `claude -p` process with no composer to type into and no interactive agent to resume; its turn end is process exit.
- **The harness is not switchable.** A soldier inherits the root session's harness (`AGENTS.md` section 4), so moving one soldier alone would break that inheritance. Model and effort are switchable per relaunch and are recorded only once an agent is confirmed.
- **`bin/cs-spawn.sh --relaunch` refuses independently** unless the recorded pane is positively agent-free AND its shell is sitting in the recorded worktree, so a replacement can never join a live agent or start outside the copy holding the work. `bin/cs-control.sh` makes the same worktree check before stopping the old agent, so a drifted pane is a byte-identical refusal instead of a post-stop failure. It also refuses the dispatch policy: a relaunch keeps the profile the task was dispatched on, so a policy edited since then never silently moves a running task's model.

## Verification

- `tests/cs-control.test.sh` - the verb allowlist, exact-id scoping, the capo and headless refusals, the endpoint refusals, and every interrupt and exit postcondition, against a stubbed herdr.
- `tests/cs-control-relaunch.test.sh` - the transaction: refusals leaving records and the brief byte-identical, the note append, resume-vs-cold selection, the pid and session-id proofs, rollback reporting after a failed launch, and the journal surviving a kill mid-transaction.
- `tests/cs-lifecycle-live.test.sh` and `tests/cs-lifecycle-claude-live.test.sh` - the same verbs against a real agent in an isolated herdr lab, per harness.
