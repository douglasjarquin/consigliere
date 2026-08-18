# Authority model

This document formalizes the three-principal authority model required by master-prompt sections 5 and 6, and provides the authority matrix that every subsequent phase must be checked against. It is the single source of truth for "who can do what" in consigliere-next; any capability API, CLI command, or socket protocol message that is not traceable to a row in the matrix below should be treated as a design defect.

The model exists because of a real, dated, first-party incident, not as speculative hardening. See `failure-corpus.md` entry C6 (SEC-01/SEC-02): a soldier's own status text was, in the legacy system, distilled by an away-mode daemon and typed into the orchestrator's own pane under an "away-supervisor" envelope, using a Unicode marker sequence that was never an authenticity control, only a disambiguation convention. Any agent capable of writing its own status text could emit the same marker and have arbitrary text appear with the apparent authority of a trusted supervision directive. SEC-01 (the specific daemon that did this) was closed by deleting it outright. SEC-02, the underlying structural gap, was left explicitly open in the legacy documentation, because a marker convention read by a language model is not a cryptographic authenticity boundary, and a cryptographic signature would not help either, since a language model cannot verify an HMAC. The only real fix is architectural: never let a lower-trust principal's text travel on a channel that a higher-trust principal's directive also travels on.

## The three principals

### 1. Attempt principal

An Attempt (a Soldier, a scout, a reviewer, a repairer, a validator) is the process actually doing work. It is the least trusted principal in the system, because it is the principal most exposed to adversarial or unpredictable input: source code, tool output, and in the coding-agent case, the full contents of a codebase and its dependencies, any of which may contain adversarial content aimed at the model driving the Attempt (prompt injection).

An Attempt authenticates to the daemon using a short-lived capability credential scoped to exactly one `attempt_id`, one `mission_id`, an explicit allow-list of operations, an expiration, and a fencing token (master-prompt section 5.1). The fencing token is what makes supersession safe: once a newer Attempt or Mission state supersedes an older Attempt, the older Attempt's fencing token is invalidated, and any command it sends afterward is rejected by the daemon, not merely ignored by convention (master-prompt section 14 invariant 10).

### 2. Model advisory principal

A root Consigliere or Capo model session is more trusted than an Attempt in the sense that it is expected to reason about Mission-level and project-level concerns, but its output is never treated as an authoritative action by itself. Everything a model advisory session produces is a recommendation: a draft Mission request, a draft answer to a Question, a draft integration recommendation, a request for the boss's attention. The daemon never treats model-produced text as having executed an authority transition merely because the text reads as if it had.

This is the direct structural answer to SEC-02: no matter how convincingly a model advisory session's output is phrased, or what marker bytes it contains, it cannot itself grant work authorization, expand scope, grant a validation waiver, authorize integration, or execute a merge, because those operations require a distinct authority transition that only the boss principal's channel can produce (master-prompt section 5.2).

### 3. Boss principal

Only a privileged, non-model, foreground client may answer boss-authority Questions, grant work authorization, expand scope, grant waivers, authorize exact-SHA integration, or execute destructive commands. The boss credential is never available inside a model sandbox; it exists only in a channel a model process cannot reach, regardless of what any model session (root Consigliere, Capo, or Attempt) attempts to do or say (master-prompt section 5.3).

The model may recommend a command. It cannot execute the authority transition that command represents. This is the load-bearing distinction: recommending and authorizing are different operations on different channels, and the system must never conflate "a plausible-sounding recommendation was produced" with "authorization occurred."

## Authority matrix

| Operation | Attempt | Model advisory (root Consigliere / Capo) | Boss principal |
|---|---|---|---|
| Report progress | yes | n/a | n/a |
| Open a Question | yes (own Mission/Attempt scope only, while not fenced) | no (may draft a recommended answer, not open one on an Attempt's behalf) | n/a |
| Answer a non-boss-authority Question | no | yes, where explicitly delegated non-boss authority exists | yes |
| Answer a boss-authority Question | no | no | yes |
| Create an artifact reference | yes | no | n/a |
| Report a checkpoint commit | yes | no | n/a |
| Request validation | yes | no | n/a |
| Report completion | yes | no | n/a |
| Draft a Mission request | no | yes | n/a |
| Authorize work (create/consume a `work` Authorization) | no | no | yes |
| Expand Mission scope | no | no | yes |
| Grant a validation waiver | no | no | yes |
| Recommend an integration action | no | yes | n/a |
| Authorize integration (exact-SHA) | no | no | yes |
| Execute a merge | no | no | yes (via the daemon's sole Integration Coordinator code path) |
| Push from the trusted mirror | no | no | daemon-executed only, triggered by boss authorization |
| Read own Mission/Attempt state | yes (own scope only) | yes (authorized state) | yes |
| Read another Mission's state | no | only if authorized to read it | yes |
| Read daemon state directly (DB, filesystem) | no | no | no (even the boss principal interacts through the daemon's API, not by reading SQLite files directly, to preserve the single-writer and audit-event guarantees) |

Any cell not listed above should be treated as "no" until an explicit design decision adds it, following master-prompt section 25.2's rule that a correctness-relevant capability must be added deliberately, in code, with a test, never by omission or convention.

## Why this is enforced structurally, not conventionally

The legacy SEC-02 finding is proof that a convention-based separation (a marker byte sequence, a naming convention, a documented expectation that "soldiers don't talk to the boss directly") degrades under the exact condition it exists to guard against: adversarial or unexpected content reaching a principal that was assumed to only ever see trusted input. Consigliere-next's authority boundaries must instead be enforced at the channel and capability-credential level:

- An Attempt's capability credential is scoped by the daemon at issuance time and re-validated, including its fencing token, on every single API call it makes. There is no path by which an Attempt's own request can widen its own scope.
- A model advisory session interacts with the daemon through the same kind of scoped, non-boss channel; even if a model session is compromised (by prompt injection from adversarial code or tool output), the worst it can do is generate a bad recommendation, because it has no channel through which a recommendation becomes an authorization.
- The boss principal's channel is the only channel from which a boss-authority Question can be answered or a boss-authority command accepted, and that channel is unavailable inside any model sandbox by construction (master-prompt section 5.3), not merely by policy.

## Traceability to Phase 0/2/7 verification

This document is a specification, not proof. The specific spikes and tests that must demonstrate these boundaries actually hold, before any production cutover, are:

- **Phase 0 Spike D (agent isolation)**: a model-like process must be shown incapable of reading SQLite, reading the trusted mirror, connecting to the boss channel, accessing another Mission's workspace, reading adapter credentials, or altering runner manifests.
- **Phase 2 tests** (master-prompt section 17): a fenced Attempt's late output must be rejected; an Agent that sets malicious hooks, fsmonitor, credential helper, or origin must be unable to affect privileged Git operations; an Agent must be unable to access the daemon home or another Mission.
- **Phase 7 chaos/security suite** (master-prompt section 22): prompt injection requesting a boss answer; prompt injection requesting a merge; a stale model attempting a boss answer; an Attempt attempting the boss socket, SQLite, another workspace, the trusted mirror, or an adapter credential.

Until every item above has a green, automated, adversarial test (not a manual walkthrough), this authority model must be treated as unproven, and master-prompt section 6's rule stands: do not proceed to production cutover with unrestricted same-user Agent access to daemon state.
