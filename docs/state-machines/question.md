# Question state machine

## Purpose

A Question is how an Attempt (or, less commonly, a Mission-level process) asks for human input without ever blocking a live process on the answer.
The entire design goal of this state machine is captured in one rule: a Question is acknowledged only after durable commit, and once acknowledged, no Attempt, model session, or Made process needs to still exist for the Question to eventually be answered.

Questions carry an explicit authority requirement.
Some Questions can be answered by a delegated advisory principal (a project-scoped policy, a Capo's advisory reasoning); others require the boss principal specifically.
This field, not the asker's identity, determines who may transition a Question to `answered`.

## States

- `open` - the Question has been durably persisted and acknowledged to the asking Attempt, but has not yet been routed to a specific answering channel.
- `routed` - the Question has been assigned a route (typed deterministic policy, project advisory reasoning, Consigliere advisory reasoning, or boss inbox) and, if best-effort notification is configured, a notification has been attempted.
- `answered` - a principal with sufficient authority for this Question's `requested_authority` has recorded an answer.
- `withdrawn` - the Question no longer needs an answer because the situation that prompted it no longer applies (for example, the Mission was canceled), and no Attempt is waiting on it.
- `expired` - the Question exceeded a policy-defined time-to-answer without being answered, and was closed by policy rather than by a principal; this is distinct from `withdrawn` because it represents an accountability gap (someone should have answered and did not) rather than a moot question.
- `superseded` - a newer Question has replaced this one because the Attempt that asked it was itself superseded (Attempt-scoped Questions supersede with the Attempt) or the subject changed materially.

## Transition table

| From | To | Trigger | Guard | Side effects |
|---|---|---|---|---|
| (none) | `open` | Attempt capability call `question.open` | (1) Attempt capability is valid and not fenced (2) Attempt's fencing token matches its Mission's current Attempt (3) `request_id` has not been seen before for this Attempt, or if seen, this is treated as an idempotent replay returning the existing Question, not a new row | Question row inserted; Mission blocker of kind `question` opened; `question.opened` event; all committed in one transaction *before* acknowledgement is sent back to the Attempt |
| `open` | `routed` | routing policy evaluation runs (synchronous or async, but always after commit) | none | `routing_reason` and route recorded; outbox item enqueued for best-effort notification; `question.routed` event |
| `routed` | `answered` | `question.answer` command from a principal | (1) if `requested_authority` is `boss`, the acting principal must be the boss principal on the privileged channel (2) if `requested_authority` allows delegated authority, a project-scoped or Consigliere-advisory principal may answer, but a model-advisory session answering a boss-authority Question is rejected outright (3) the Question is not already `answered`/`withdrawn`/`expired`/`superseded` | `answer`, `answered_by_principal`, `answer_channel`, `answered_at` recorded; `question.answered` event; if this Question was blocking a checkpointed Attempt, a continuation Attempt may now be scheduled |
| `open` | `answered` | boss answers directly before routing completes (race between routing and a boss who is already watching) | same authority guard as above | same side effects as above; routing is skipped, not retried |
| `open`/`routed` | `withdrawn` | the blocking condition that created this Question no longer applies (Mission canceled, subject resolved another way) | an explicit withdrawal command references the reason | `question.withdrawn` event; Mission blocker closed with reason `withdrawn` |
| `open`/`routed` | `expired` | policy timer (evaluated by the daemon, not by any Attempt or model process) fires with no answer recorded | Question's `blocking_scope` and project policy define the timeout; expiry never happens silently, it always creates or reinforces an incident | `question.expired` event; Incident opened; Mission blocker remains open until a human resolves the underlying incident (expiry does not silently clear the blocker) |
| `open`/`routed` | `superseded` | the asking Attempt is superseded, and this Question is Attempt-scoped (not Mission-scoped) | Question's `blocking_scope` is `attempt`, not `mission` | `question.superseded` event; Mission blocker closed with reason `superseded`, but if the Mission still needs an answer, the new Attempt may open a fresh Question |

## Boss-authority vs delegated-authority modeling

Every Question row carries a `requested_authority` field, populated at open time by whoever asked (an Attempt names what kind of authority its question needs, but does not get to grant itself that authority).
This field takes one of two shapes:

- `boss` - only the boss principal, acting through the privileged foreground client, may transition this Question to `answered`. A model-advisory session (root Consigliere or Capo) may draft a recommended answer and attach it as `recommendation`, but `answered_by_principal` for a `boss`-authority Question must be `boss` or the transition is rejected outright, not merely discouraged.
- a named delegated scope (for example `project_policy` or `capo_advisory`) - a model-advisory principal acting within that explicit, pre-granted delegation may answer directly. This still requires that the delegation itself was established by a boss-granted Authorization (scope `policy_override` or similar) at some earlier point; a model cannot invent its own delegated authority by simply naming itself as the answering principal.

Two structural rules follow directly from Section 5 and Section 10.5 of the architecture:

- **A fenced Attempt cannot open a Question.** The `open` transition's guard explicitly checks the Attempt's fencing token against its Mission's current Attempt before the row is even inserted; a superseded Attempt attempting `question.open` is rejected at the capability layer, before this state machine is invoked at all.
- **Attempt-scoped Questions supersede with the Attempt; Mission-scoped Questions survive Attempt replacement.** `blocking_scope` is set at open time and never changes; it determines which side effect fires when the Attempt is superseded. A Question asked about "should I use approach A or B for this specific sub-task" is Attempt-scoped and dies with that Attempt. A Question asked about "should we still land this Mission given a discovered exposure" is Mission-scoped and must survive being re-asked by whichever Attempt continues the Mission, which is why it is never silently dropped, only explicitly `superseded` if genuinely obsolete or left open if still relevant.

## Terminal states

`answered`, `withdrawn`, `expired`, and `superseded` are all terminal.
Nothing reopens a Question row directly; if the same underlying issue recurs, a new Question is opened, deliberately, so that the audit trail shows a real second event rather than a mutated first one.
`expired` is terminal for the Question but not necessarily for the underlying problem: it always leaves an Incident open, so an expired Question can never be mistaken for a resolved one by anything reading only Question status.

## Invariants enforced by this state machine

- **Invariant 2** (a Question is acknowledged only after durable commit): the `(none) -> open` transition's side-effect ordering is explicit: row insert, blocker open, event append, and transaction commit all happen before the acknowledgement is sent back over the Attempt's capability channel.
- **Invariant 3** (human input never retains a live Agent or validator): nothing in this state machine has an Attempt or Made process waiting synchronously; the Attempt that opened a Question is expected to checkpoint and terminate (see attempt.md), and the eventual `answered` transition triggers a fresh continuation Attempt rather than resuming a paused one.
- **Invariant 13** (model sessions cannot exercise boss authority): enforced directly in the `-> answered` guard, keyed off `requested_authority`.
- **Invariant 22** (duplicate commands are logically idempotent): the `open` transition's `request_id` deduplication guard exists specifically so that an Attempt retrying an acknowledgement it never received (because the daemon crashed between commit and reply) creates exactly one Question, not two.
- **Invariant 26** (every non-runnable Mission has a deterministic blocker explanation): every non-terminal Question state keeps its Mission blocker open; `cs why` reads the blocker, not Question prose.
- **Invariant 29** (superseding an Attempt deterministically handles its open Questions): the `blocking_scope`-driven `-> superseded` transition is that deterministic handling, defined once here rather than reimplemented at each call site that supersedes an Attempt.

## Failure-mode traceability

- Legacy Consigliere's `docs/architecture.md` explicitly documents that "crew status files are append-only wake-event logs, not current-state fields," and that this "can bury an earlier still-open needs-decision/blocked under later unrelated appends," requiring a separate cursor-folded "OPEN DECISIONS" re-derivation pass to recover current status from a log.
This state machine exists precisely so that Question status is never derived by re-scanning a log: `status` is a real column on a real row, updated in place by the transitions above, and `cs questions`/`cs why` query it directly.
- Legacy Consigliere's SEC-01/SEC-02 findings (`docs/operational-input-provenance.md`) describe a soldier's own status text being distilled, verbatim, into a "trusted" supervision envelope typed into the boss's own pane, with the acknowledged structural weakness that a text marker is forgeable by any agent reaching that channel, and that "an LLM reader cannot verify a cryptographic HMAC."
This is the direct justification for making `requested_authority` and the `-> answered` authority guard a database-enforced check at the daemon layer, not a convention observed by whichever process happens to be reading a channel; the daemon, not a model reading text, is what refuses an unauthorized answer.
- The Made grounding fork's confirmed finding that `chain.parkForApproval` blocks a live goroutine on `ReviewDecisions.Wait`, with the only unblock path being an interactive CLI prompt reading stdin from inside the same process, is the direct negative example this Question model is built against: Made's review-decision mechanism has no analog to `open`/`routed` at all, it simply blocks; this state machine is what a Gate's `needs_decision` outcome is translated into once it reaches Consigliere (see `docs/protocols/made-managed-mode.md`).

## Open questions carried forward (not resolved here)

- Exact default expiry policy per `blocking_scope` and `requested_authority` combination (a boss-authority Question probably needs a longer or absent default timeout than a project-advisory one); left as a project-level policy value.

## Decision (2026-08-19): Mission-scoped Questions stay open by default across supersession

Confirmed: a Mission-scoped Question defaults to staying open when the Attempt that raised it is superseded, rather than requiring an explicit relevance judgment before carrying forward.
An open question almost always still matters to the Mission regardless of which Attempt raised it, and requiring a judgment call at every supersession would risk silently dropping a Mission-scoped Question, which would violate Invariant 29's intent.
Explicit withdrawal remains the only way to close a Question early; supersession alone never does.
