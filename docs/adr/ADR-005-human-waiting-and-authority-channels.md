# ADR-005: Human waiting and authority channels

## Status

Proposed.

## Context

The single strongest, most direct piece of grounding evidence for this rewrite is Made's confirmed current behavior when a validation stage reports pending findings.

`chain.parkForApproval` (`internal/orchestrator/workfunc.go:324-342`) is called from both the review and document stages, and it does this:

```go
_ = c.rm.UpdatePendingFindings(c.runID, findings)
decision, err := c.reviewDecisions.Wait(c.ctx, c.runID, stage)   // blocks
_ = c.rm.UpdatePendingFindings(c.runID, nil)
```

`ReviewDecisions.Wait` (`internal/daemon/reviewdecisions.go:61-80`) is a literal blocking channel select: `select { case decision := <-ch: ...; case <-ctx.Done(): ... }`.
The only ways to unblock it are `Set()` (driven by `made review`'s interactive stdin prompt) or context cancellation.
This is not a metaphorical or inferred instance of "a process waits on a human"; it is a live goroutine, holding an open worktree and daemon connection, parked indefinitely on a channel read, for however long a human takes to respond.
Because Made's `RunManager` and `ReviewDecisions` state are both unpersisted in-memory maps (ADR-002), a daemon restart while that goroutine is parked loses the pending finding, the parked decision, and the run itself, simultaneously.

Legacy Consigliere's own incident record, independently, shows what goes wrong when the channel that carries an answer is not cleanly separated from the channel that carries ordinary agent narration.
`docs/operational-input-provenance.md` documents SEC-01 (closed) and SEC-02 (open, structural): the away-mode daemon (`cs-daemon.sh`, since deleted) distilled soldier-authored `state/<id>.status` lines verbatim into a "trusted" `away-supervisor` envelope typed directly into the orchestrator's own pane.
A Unicode marker (`U+2063`) was used to mark that envelope as authoritative, but the document itself notes the marker is a boss-disambiguation aid, not an authenticity control: any agent producing that byte sequence could cause its own text to be read as if it were Consigliere's own supervision directive.
SEC-01 was closed by deleting the daemon entirely, not by patching the marker check.
SEC-02 remains open precisely because prefix-matching on a marker is still forgeable by any agent whose text reaches the reading orchestrator's pane, and the document explicitly notes that an LLM reader has no way to verify a cryptographic HMAC even if one were added.
This is the exact attack this rewrite's authority-channel separation exists to make structurally impossible, not just harder: a boss-authority answer must originate from a channel a model-controlled process cannot write to, not from text a model-controlled process can shape.

## Decision

No process may remain blocked waiting for human input, full stop: not a model turn, not a Soldier, not a validator, not a Made run, not a goroutine, not a GenServer call, not a shell process, not a terminal session.
When human input is required, the sequence is: persist a Question (or Decision request), checkpoint to a committed SHA if work must resume, terminate or release the active execution, answer through a privileged channel, then create a new continuation action.
This directly replaces Made's `parkForApproval`/`Wait` pattern (ADR-007 covers the Made-specific managed-mode redesign this implies) and formalizes what legacy Consigliere's `cs-decision-hold.sh` and `cs-afk-return.sh` were already reaching for with markdown-backed backlog items and fail-closed catch-up markers, but now as durable database rows rather than flat files.

Three distinct principals are established, matching master-prompt section 5:

- **Attempt principal**: a short-lived, scoped capability credential (bound to `attempt_id`, `mission_id`, an explicit allowed-operations list, an expiration, and a fencing token). It can report progress, open a Question, and report a checkpoint. It cannot answer a boss Question, authorize work, or grant a waiver.
- **Model advisory principal**: root Consigliere and Capo model sessions may read authorized state and recommend, draft, or request attention, but their output is advisory text, never an authority transition, regardless of how confidently or how much like "Consigliere" it is phrased.
- **Boss principal**: only a privileged, non-model foreground client may answer a boss Question, grant authorization, expand scope, grant a waiver, or authorize integration. This credential is never available inside a model sandbox.

Answering authority is determined by which channel a message arrives on, not by any marker, prefix, or claim embedded in the message's text.

## Consequences

- Made-style parked goroutines become structurally impossible in the daemon's own domain: a Question always resolves as "persist, release, wait for an out-of-band answer, then continue," never as a live in-process wait.
- SEC-02-style laundering becomes structurally impossible for the rewrite's own boss-authority Questions, because the boss principal's channel is not reachable from any model-controlled process, unlike a marker embedded in ordinary text that any agent can reproduce.
- This requires building and maintaining a real privileged-channel boundary (a foreground client with credentials no sandboxed model process can obtain), which is nontrivial infrastructure; it is accepted because the alternative (trusting text-embedded markers) is a proven, exploited-in-principle failure mode in the predecessor system.
- Model-advisory text can still recommend an answer or a merge, but recommending is not authorizing; every consequential transition still requires a boss-principal action, which is intentionally slower than letting a sufficiently persuasive model session act directly.

## Alternatives considered

**Keep a blocking wait, but add a timeout.** Rejected: a timeout does not solve the underlying problem (a resource is held for the duration of the wait, and the run's internal state is lost if the daemon dies mid-wait); it only bounds how long the damage lasts.

**Marker-based authority separation** (an improved, harder-to-forge marker, e.g. an HMAC), as SEC-02's own remediation note in legacy Consigliere considers and rejects. Rejected for the same reason legacy Consigliere's own documentation rejects it: an LLM reader cannot verify a cryptographic signature, so any marker-in-text scheme is fundamentally a heuristic, not a boundary, no matter how hard the marker is to forge by hand.

**Let Capo/model sessions hold delegated non-boss authority broadly** (e.g., any advisory session can resolve any Question). Rejected as the default: master-prompt section 5.2 permits delegated non-boss authority only where explicitly granted, and boss-authority Questions specifically require the boss channel with no exception.

## Revisit trigger

Reopen this ADR if the Phase 4 kill-everything acceptance test (start Mission, mark boss away, Soldier opens a blocking boss Question, terminate every live process including the daemon, restart, run `cs return`, confirm the Question appears exactly once and only the boss channel can answer it) cannot be made to pass, or if a real production incident demonstrates the privileged channel itself can be reached from a model sandbox.
