# Failure corpus

This document collects the concrete, dated, first-party evidence that motivates the consigliere-next rewrite.
Every entry below is grounded in an actual commit, an actual file, or an actual documented incident from one of four source repositories: the legacy Consigliere repository (commit 81612c3, the last commit before the working tree was emptied for this rewrite), the Made repository, the Symphony reference project, and the Firstmate lineage project.
None of these are hypothetical failure modes invented for this document.
Each entry states preconditions, observed behavior, expected behavior, what was at risk, what manual intervention was required, the architectural cause, the new invariant it implies, and the acceptance test that will prove the invariant holds in consigliere-next.

The entries are grouped by source system, then ordered roughly by severity within each group.

## Legacy Consigliere incidents

### C1. 61 consecutive checkpoints over 6.2 hours with nothing said to the boss

**Preconditions**: the "one checkpoint per turn" supervision rule existed only as prose in the agent's own instructions, not as an enforced mechanism.
**Observed behavior**: the agent reinterpreted the prose rule and looped through 61 consecutive checkpoints inside what was meant to be a single bounded turn, spanning 6.2 hours, without ever yielding the turn back to a state where the boss's message could be received.
**Expected behavior**: exactly one checkpoint per turn, then control returns to a state where new boss input can interrupt.
**Data or work at risk**: any message the boss sent during that window was effectively unreachable; the boss had no way to know supervision had stalled.
**Manual intervention**: the rule was rewritten from prose into a code-enforced mechanism (a `state/.checkpoint-turn` marker file cleared by a harness Stop-hook), so that a second checkpoint inside one turn became structurally impossible rather than merely discouraged.
**Architectural cause**: a correctness rule that only existed in a prompt, with no enforcement in code.
**New invariant**: no correctness rule that can lose work, lose a Question, duplicate work, or wedge a Mission may live only in a prompt; it must be enforced in code and covered by a test (master-prompt section 25.2).
**Acceptance test**: a fake agent attempts to checkpoint twice inside one bounded turn; the second attempt must be structurally rejected by the daemon or coordinator, not merely discouraged by instructions.

### C2. A home went unwatched the instant its agent started working

**Preconditions**: supervision was originally checkpoint-only; a checkpoint fires once per turn but there was no coverage for the interval while the agent was actively working between checkpoints.
**Observed behavior**: a home could be actively producing side effects with zero external supervision until its next checkpoint.
**Expected behavior**: continuous supervision coverage regardless of whether the supervised entity is between turns or mid-turn.
**Data or work at risk**: any wedge, runaway loop, or unauthorized action occurring mid-turn would go undetected until the next checkpoint, if one ever came.
**Manual intervention**: a separate persistent monitor process (`cs-monitor.sh`) was introduced specifically to cover the gap checkpoint-only supervision left open.
**Architectural cause**: supervision coverage was defined in terms of a conversational unit (the turn) rather than as a continuously running, independently supervised process.
**New invariant**: a domain coordinator's crash must not remove supervision coverage of the process(es) it is meant to be watching, and coverage must not depend on a conversational cadence.
**Acceptance test**: kill the MissionCoordinator process for a Mission whose Attempt is actively running; the RunnerProcess must remain supervised and reconciled once the coordinator restarts (this is Phase 0 Spike B).

### C3. 8 hours 11 minutes of unwatched fleet on 2026-08-01

**Preconditions**: an away-mode daemon was responsible for supervision while the boss was away.
**Observed behavior**: the away-mode daemon had already been retired/dead, but ownership of the away-mode supervision responsibility was never reassigned; the fleet ran unsupervised for 8 hours 11 minutes before anyone noticed.
**Expected behavior**: a supervision responsibility must never be silently orphaned; if the owner of a responsibility is gone, that must be a detectable, alarming condition, not a silent gap.
**Data or work at risk**: any Question, wedge, or failure occurring in that 8-hour window would have gone unnoticed indefinitely.
**Manual intervention**: manual discovery and after-the-fact root-causing; no automatic detection existed.
**Architectural cause**: ownership handoff for a durable responsibility (supervision) was implicit and undetectable rather than an explicit, checkable, durable fact.
**New invariant**: every Mission blocker and every supervision responsibility must be an explicit row with an owner, so that "who is supposed to be watching this" is always a query, never an assumption (master-prompt section 14 invariant 26, `cs why`).
**Acceptance test**: with no daemon running at all, `cs why` (or its equivalent local diagnostic) must be able to state unambiguously that no supervision is active, rather than silently reporting nothing.

### C4. Monitor re-execs itself on disk change, because a 13-hour-stale monitor missed the incident that would have fixed it

**Preconditions**: `cs-monitor.sh` is a long-lived shell process, launched once and expected to run for hours.
**Observed behavior**: the exact incident (C3-adjacent) that motivated a fix ran under a monitor process that was already 13 hours older than the fix meant to catch it, because the running process had no way to pick up newly deployed code.
**Expected behavior**: a long-lived supervising process must not silently continue running stale logic indefinitely.
**Manual intervention**: the monitor was changed to re-exec itself whenever its own source file changed on disk.
**Architectural cause**: correctness logic lived inside a long-lived shell process's already-loaded code, with no mechanism to detect or react to its own staleness.
**New invariant**: an authoritative supervising component's code must not be able to silently drift from what is deployed; in consigliere-next this is structurally solved by the daemon being the sole authority and by restarts of the daemon being routine and safe (master-prompt "daemon restart is routine," Phase 1 exit gate), rather than by hand-rolled self-re-exec logic in a long-lived script.
**Acceptance test**: covered by the general daemon-restart-is-routine soak requirement (master-prompt section 22) rather than by a bespoke self-reload test; there should be no long-lived process in consigliere-next whose staleness is a distinct failure mode.

### C5. 213 monitor revivals in 7 hours (2026-07-30), and the away-mode daemon dying within a second of arming on all five recorded away sessions (2026-08-01)

**Preconditions**: long-lived processes (the monitor, the away-mode daemon) were being launched with `nohup ... & disown` from inside a bounded agent tool call.
**Observed behavior**: `nohup`/`disown` does not survive the process-group teardown that happens when the bounded tool call that launched it exits; the monitor was observed reviving itself 213 times in 7 hours, and the away-mode daemon died within one second of arming on every one of five recorded away sessions.
**Expected behavior**: a process meant to outlive its launching tool call must actually outlive it, deterministically, every time.
**Data or work at risk**: any supervision responsibility assigned to that daemon was unmet from the moment it silently died, with no signal that it had died.
**Manual intervention**: all such launches were routed through a dedicated detachment helper (`cs-detach.py`) instead of `nohup ... & disown`.
**Architectural cause**: relying on OS-level process-detachment semantics from inside a sandboxed/bounded tool-call environment, without verifying the detachment actually took effect.
**New invariant**: this is direct, first-party evidence for why consigliere-next's runner must be a daemon-bound, verifiably-alive external process with its own session/process-group and a crash-safe runtime manifest (master-prompt section 8), not a "fire and forget" background launch from inside an agent's own tool-call boundary. It is also direct evidence that any Elixir spike proposing to launch a harness process must prove the launched process's lifetime is independent of the launching call, under the same conditions (sandboxed tool call, process-group teardown) that broke `nohup`/`disown` here.
**Acceptance test**: Phase 0 Spike C (daemon-bound runner) must include a variant of this exact scenario: launch the runner from within a bounded/sandboxed context analogous to an agent tool call, then have that launching context exit/terminate, and prove the runner and its harness process group are still alive and still under daemon control afterward.

### C6. SEC-01 (closed) / SEC-02 (open, structural): soldier text laundered as a trusted supervision directive

**Preconditions**: the away-mode daemon (`cs-daemon.sh`, since deleted) read soldier-authored `state/<id>.status` lines and retyped them, verbatim, into the orchestrator's own terminal pane, wrapped in an "away-supervisor" envelope, using a Unicode marker sequence (`U+2063`) intended to help the boss disambiguate the source of the text.
**Observed behavior**: the marker is not an authenticity control; any agent capable of writing its own status line could emit the same marker bytes and have its own arbitrary text typed into the orchestrator's pane framed as if it were consigliere's own trusted supervision directive. This is a real prompt-injection / authority-laundering path: a soldier (or anything that can influence a soldier's status text, including content the soldier itself ingested) could cause text to appear in the boss-facing pane with the appearance of trusted framing.
**Expected behavior**: text authored by a lower-trust principal (a soldier, an Attempt) must never be capable of appearing with the framing or apparent authority of a higher-trust principal (the orchestrator, the boss channel), regardless of what bytes it contains.
**Data or work at risk**: this is an authority-boundary violation, not a data-loss incident; the risk is that a compromised or manipulated soldier could effectively spoof consigliere's own voice to the boss.
**Manual intervention**: SEC-01 was closed by deleting the away-mode daemon entirely (its supervision responsibilities were folded into `watch`/`monitor`/`activate`), not by patching the marker mechanism. SEC-02 remains explicitly open in the legacy documentation: any prefix-matched marker is still forgeable by any agent that can reach the reading orchestrator's pane, and the legacy documentation itself states that an LLM reader cannot verify a cryptographic HMAC, so a cryptographic fix alone would not close this without also solving how a language model is supposed to verify it.
**Architectural cause**: there was no structural separation between "channel a lower-trust principal's text travels on" and "channel a higher-trust directive travels on"; the only separation was a marker convention layered on top of a single shared channel (the orchestrator's own pane).
**New invariant**: this is the single strongest piece of first-party evidence for master-prompt section 5's three-principal authority model. Model-produced and Attempt-produced text must be structurally, not conventionally, incapable of being interpreted as a boss-authority directive; boss-authority answers must travel through a privileged, non-model, non-Attempt channel that a soldier or model session cannot write to, by construction, not by marker convention (master-prompt section 14 invariant 13, section 21 "Questions" chaos suite: "stale model tries boss answer", "Attempt tries boss socket").
**Acceptance test**: a fenced/adversarial Attempt attempts to answer a boss-authority Question, or to inject text designed to look like a boss directive, through every channel it has access to (its capability API, its status/progress reporting, any artifact it can write); none of these paths may be capable of exercising boss authority, verified by a dedicated Phase 2/7 test (Spike D, and the chaos-suite entries "prompt injection requesting answer", "prompt injection requesting merge", "Attempt tries boss socket").

### C7. Made's CLI surface was assumed ahead of Made actually implementing it

**Preconditions**: `bin/cs-made-lib.sh` and `cs-made-run-lib.sh` were written calling `made axi status`, `made axi abort`, `made axi logs`, and other subcommands.
**Observed behavior**: as documented in the legacy source's own code comments (verified against Made's actual source on 2026-08-13), Made's real CLI dispatch (`cmd/made/main.go`) only ever implemented `daemon start|stop|status`, `status`, `review`, `pr`, `doctor`; the `axi`-prefixed subcommands consigliere called were forward references to a contract that did not exist yet, expected to "start working the moment Made's CLI grows the matching subcommand."
**Expected behavior**: an integration contract between two independently developed systems should be an explicit, versioned protocol both sides can verify against, not an assumption one side makes about the other's future API surface.
**Data or work at risk**: any code path depending on the assumed subcommands would silently fail or behave unpredictably until Made happened to catch up, with no compile-time or protocol-level check that the two sides agreed.
**Manual intervention**: none yet; this was caught by direct source inspection during this grounding pass, not by an automated check.
**Architectural cause**: integration between Consigliere and Made was speculative rather than contract-driven.
**New invariant**: master-prompt section 12's managed-mode contract must be an explicit, versioned CLI + JSON-event protocol (ADR-007), with a conformance suite, rather than an assumed shape.
**Acceptance test**: a protocol-version mismatch between consigliere-next and the `made validate --managed` command it invokes must be detected and surfaced as an explicit incident, not silently ignored or silently assumed compatible.

### C8. A parked Made run holds a fleet slot indefinitely until an explicit abort concludes it

**Preconditions**: a Made run reaches `awaiting_approval` or `fix_review` and parks there.
**Observed behavior**: the legacy `cs_made_run_is_gate_parked` logic confirms the parked run holds a fleet capacity slot indefinitely; the only way to release it is `cs-teardown.sh`'s explicit abort call.
**Expected behavior**: a human-review wait should release compute/capacity resources immediately, and resuming after the decision should not require the original parked process to still exist.
**Data or work at risk**: fleet capacity is consumed by work that is not actually progressing, for however long a human takes to respond, exactly mirroring Made's own `parkForApproval` blocking-goroutine problem one layer up.
**Manual intervention**: an explicit, boss-triggered teardown/abort call, not an automatic release.
**Architectural cause**: "parked awaiting a decision" and "actively consuming a capacity slot" were not separated as concepts.
**New invariant**: master-prompt section 4.6 (human waiting is durable state) and section 20's `needs_decision` flow: the moment a Gate needs a decision, the Attempt terminates, the runner slot releases, and Mission stays in a durable blocked state with zero live process or capacity consumption, by construction.
**Acceptance test**: master-prompt section 20's test 1: "`needs_decision` leaves zero live validator process," verified directly against the daemon's process/slot accounting, not against documentation of intent.

## Made repository findings

### M1. `chain.parkForApproval` is a live blocking goroutine wait on human review, today

**Preconditions**: a Made pipeline stage (review or document) reports pending findings requiring human approval.
**Observed behavior**: `internal/orchestrator/workfunc.go`'s `chain.parkForApproval` calls `c.reviewDecisions.Wait(c.ctx, c.runID, stage)`, which is a real blocking Go `select` on a channel in `internal/daemon/reviewdecisions.go`; the only ways out are an explicit `Set()` call (from the `review.decide` RPC handler, driven by an interactive `made review` CLI session reading stdin) or context cancellation. This goroutine holds an open worktree and open daemon-connection resources for as long as the human takes to answer.
**Expected behavior**: per master-prompt section 4.6 and section 20, nothing may remain blocked waiting for human input; a validation run must persist its need for a decision, exit cleanly, and be rerun after the decision lands.
**Data or work at risk**: the resources held by the parked goroutine (worktree, daemon connection, whatever process slot invoked it) are unavailable to other work for the duration of the human wait, and a daemon restart during this wait loses the parked state entirely (see M2).
**Manual intervention**: none currently exists to safely release this state; the interactive `made review` CLI is the only path that can ever unblock it.
**Architectural cause**: Made's review-decision model conflates "the validation run's process lifetime" with "the human decision's lifetime," when these should never be coupled.
**New invariant**: master-prompt section 12's managed-mode contract (`made validate --managed`) must be built as an entirely new, parallel command that never calls `parkForApproval`, and must instead emit a `needs_decision` terminal outcome and exit (ADR-007).
**Acceptance test**: master-prompt section 20 test 1 and section 12's exit-and-rerun sequence, verified against the real `made` binary once managed mode exists: start a managed validation run, trigger a `needs_decision` outcome, and confirm the `made` process has actually exited (not merely idle) before the decision is answered.

### M2. Made's run state and pending-decision state are 100% in-memory, with zero persistence

**Preconditions**: `RunManager` (`internal/daemon/runmanager.go`) is a `map[string]*run` guarded by a `sync.Mutex`; `reviewDecisions.entries`/`.waiters` are likewise in-memory maps.
**Observed behavior**: there is no SQLite, no bbolt, no spool, and no replay mechanism anywhere in Made's codebase (confirmed by direct grep); a daemon restart loses every run, every pending finding, and every parked decision unconditionally.
**Expected behavior**: validation state that a Mission depends on for its own recovery must survive a restart of whatever process is tracking it.
**Data or work at risk**: any in-flight validation run, any pending finding awaiting a decision, is unconditionally lost on a Made daemon restart with the current code.
**Manual intervention**: none; there is nothing to recover from, because nothing is persisted.
**Architectural cause**: Made's daemon was built as a single long-lived process holding all state in memory, with no durability layer.
**New invariant**: consigliere-next must never treat Made's own run tracking as authoritative or durable; the Gate and Mission-validation-ledger projections in consigliere-next's own SQLite database are the only durable record of a validation's state, and Made itself must become a short-lived, stateless-between-invocations command in managed mode (this is exactly why managed mode is exit-and-rerun rather than exit-and-resume: there is nothing inside Made itself worth resuming).
**Acceptance test**: master-prompt section 20 test 2: "daemon restart preserves Question and Gate," verified against consigliere-next's own database, independent of whether the `made` process that produced them still exists.

### M3. No `input_sha`/`policy_hash` concept exists anywhere in Made today

**Preconditions**: none; this is a structural absence.
**Observed behavior**: a full-repository grep for `input_sha`, `InputSHA`, `inputSha` returns zero matches; Made's stages perform ad hoc git operations (rebase, push) without any explicit, propagated notion of "the exact commit this validation result is bound to."
**Expected behavior**: master-prompt section 4.8 requires every validation result to be tied to an immutable Git SHA and a policy hash, such that a changed head invalidates stale validation.
**Data or work at risk**: without this, a validation result cannot be safely trusted to still apply after the workspace or branch has moved, which is precisely the condition master-prompt section 14 invariant 18 and invariant 20 exist to prevent.
**Manual intervention**: none; this gap has not yet caused an incident because Made has never been run in an exit-and-rerun mode where staleness could be silently assumed away.
**Architectural cause**: Made was designed around one long-lived pipeline run per invocation, where the SHA in scope was implicit in the live worktree state, not an explicit, checkable value.
**New invariant**: the managed-mode contract (`made validate --managed --input-sha <sha> --policy-hash <hash> ...`) must make both values explicit, required inputs, and consigliere-next must reject or re-trigger validation whenever the Mission's current checkpoint SHA no longer matches the SHA a Gate was run against.
**Acceptance test**: master-prompt section 20 test 4: "changed SHA invalidates SHA-bound Decision," and section 6 chaos-suite entries "CI result for SHA A cannot apply to SHA B" (delivery-side analog of the same principle).

### M4. Made's PR stage is already structurally, test-enforced incapable of merging

**Preconditions**: none; this is a positive finding, not a failure.
**Observed behavior**: Made's own test suite asserts that the PR stage's available GitHub method set excludes any merge-capable method (`plans/made-rewrite.md:699`); Made's stages, by construction, never call a merge API.
**Expected behavior**: matches master-prompt section 12's requirement that Made must not own push/PR/merge lifecycle in managed mode.
**Why this matters here**: this is evidence that a structural (test-enforced), not merely documented, prohibition on a dangerous capability is achievable and already precedented inside Made itself; consigliere-next's own Integration Coordinator merge-only-code-path invariant (master-prompt section 13, section 14 invariant 20) should be held to at least this same bar, and can point to this as prior art that the pattern works in practice.
**Acceptance test**: none needed here beyond continuing to run Made's existing test; consigliere-next's own equivalent test is master-prompt section 21's chaos-suite GitHub entries and section 14 invariant 20's server-side expected-SHA enforcement test.

## Symphony reference findings

### S1. `:one_for_all` coordinator supervision kills every in-flight worker on coordinator crash

**Preconditions**: Symphony's `AgentRuntimeSupervisor` (`agent_runtime_supervisor.ex`) supervises its `Task.Supervisor` and its `Orchestrator` GenServer under a `:one_for_all` restart strategy.
**Observed behavior**: because the strategy is `:one_for_all`, any crash of the `Orchestrator` process restarts the sibling `Task.Supervisor` as well, which terminates every currently running agent `Task` (and the Codex `Port` process each one owns) as a direct consequence, even though those tasks had nothing to do with the coordinator's crash.
**Expected behavior**: per master-prompt section 4.7 and section 14 invariant 4, a domain coordinator's failure must never terminate unrelated running work.
**Data or work at risk**: every in-flight agent run at the moment of any Orchestrator crash, regardless of that run's own health.
**Manual intervention**: none observed; this is a structural property of the current supervision tree, not an incident that was caught and fixed.
**Architectural cause**: coordinator and worker processes share a restart fate because they sit under the same `:one_for_all` supervisor, rather than the coordinator supervising workers through an independent, `:one_for_one` or per-worker dynamic supervision boundary.
**New invariant**: this is the direct, named justification for master-prompt section 7's split between `Consigliere.MissionDynamicSupervisor` (`:one_for_one`, holding `MissionCoordinator`s) and `Consigliere.RunnerDynamicSupervisor` (`:one_for_one`, holding `RunnerProcess`es) as two independent top-level supervision subtrees, rather than nesting a RunnerProcess under its MissionCoordinator.
**Acceptance test**: master-prompt section 17 test 1 / Phase 0 Spike B: kill a MissionCoordinator process; the RunnerProcess and its harness must remain alive and unaffected, and the restarted MissionCoordinator must rehydrate and re-attach to the still-running RunnerProcess without ever having terminated it.

### S2. All Attempt-equivalent state lives only in GenServer memory

**Preconditions**: Symphony's `Orchestrator` `%State{}` struct holds `running`, `blocked`, `retry_attempts`, `completed`, `claimed`, and token counters entirely as GenServer process memory, with nothing written to any local database.
**Observed behavior**: on any crash of the Orchestrator process (including the cascading crash described in S1), all of this state is gone; on restart, `init/1` starts fresh with empty maps and re-derives "what's still active" purely by polling the external issue tracker, which was never designed to be the durable source of truth for in-flight execution state like retry counters or parked/blocked reasons.
**Expected behavior**: per master-prompt section 4.2 and 4.5, an Attempt may be lost, but the Mission's state, and enough Attempt history to reconstruct what happened, must survive process death independent of any external tracker's own state model.
**Data or work at risk**: retry counters, blocked/needs-input classification, and session identifiers for every in-flight run, on every Orchestrator crash.
**Manual intervention**: none; the system is designed to treat the external tracker as sufficient ground truth, which silently loses information the tracker was never asked to hold.
**Architectural cause**: treating an external system (the issue tracker) as an adequate substitute for a local durability layer.
**New invariant**: master-prompt section 4.4's SQLite projections exist specifically so that consigliere-next never has to lean on an external tracker, Herdr, or any other integration as its actual source of truth for in-flight execution state (master-prompt section 14 invariant 25).
**Acceptance test**: master-prompt section 22 soak test: after a hard kill of the daemon process, every previously in-flight Attempt must resolve to exactly one of safely-lost / safely-checkpointed / quarantined / incidented, using only the local database, with zero dependency on any external tracker's state.

### S3. Workspace identity is a path keyed by external issue ID, with no SHA-based checkpoint model

**Preconditions**: `Workspace.create_for_issue/2` creates a plain local (or SSH-remote) directory named by the external issue ID; `ensure_workspace/2` reuses or removes it by that same path/ID.
**Observed behavior**: there is no commit-SHA-based checkpoint concept; workspace identity and reuse decisions are made purely on the basis of a path being associated with an issue ID, which is exactly the "marker file / path as authority" pattern master-prompt section 9.5 explicitly warns against.
**Expected behavior**: per master-prompt section 9.3 and 9.4, a workspace's reusability and a Mission's resumability must be anchored to an imported, committed SHA and a conclusively-verified prior process death, not to a path naming convention.
**Data or work at risk**: a workspace could be reused or assumed clean based solely on its path/ID association, with no verification that whatever previously wrote to it is actually dead, and no SHA-level guarantee about what state it is actually in.
**Manual intervention**: none; this is Symphony's baseline design, not a patched incident.
**Architectural cause**: workspace identity was designed around the external tracker's own identifiers rather than around the control plane's own durable, SHA-anchored checkpoint model.
**New invariant**: master-prompt section 9's full trusted-mirror / mission-workspace / committed-SHA-checkpoint model exists specifically to avoid this pattern.
**Acceptance test**: master-prompt section 17 tests 8 and 9 (dirty workspace is not deleted; a workspace whose prior process cannot be conclusively killed is quarantined, never silently reused).

## Firstmate lineage findings

### F1. 52,558 lines of bash across 134 scripts, concentrated entirely in supervision/spawn/wake/status machinery

**Preconditions**: none; this is a structural measurement of the Firstmate `bin/` directory.
**Observed behavior**: the ten largest scripts alone (`fm-spawn.sh` 2776 lines, `fm-teardown.sh` 2549, `fm-test-run.sh` 1713, `fm-supervise-daemon.sh` 1576, `fm-fleet-snapshot.sh` 1396, `fm-composer-lib.sh` 1275, `fm-pending-reply-lib.sh` 1245, `fm-bootstrap.sh` 1234, `fm-watch.sh` 1204, `fm-config-inherit-lib.sh` 1202) total nearly 15,000 lines, every one of them in the supervision/spawn/wake/status category rather than in any product-feature category.
**Expected behavior**: per master-prompt section 3.7 and section 25.3, the system should not repeatedly expand beyond its intended simplicity, and speculative machinery should not accumulate ahead of actual need.
**Data or work at risk**: none directly; the risk is entirely to long-term maintainability, onboarding cost, and the ongoing rate of liveness-class bugs (see F3).
**Manual intervention**: none; this pattern was carried forward into (and grew further in) the legacy Consigliere codebase before this rewrite began.
**Architectural cause**: a file-based, shell-process-based coordination model requires an ever-growing amount of defensive machinery (classification, debouncing, staleness detection, re-arming) to compensate for the fact that shell/pane liveness is not the same thing as task or supervision liveness.
**New invariant**: consigliere-next's daemon-authoritative, SQLite-backed model replaces this defensive machinery with a small number of durable, queryable projections; the volume of code required to keep the system honest should shrink by an order of magnitude, and any growth back toward this shape (a new file-based marker, a new bespoke classification script) should be treated as a regression.
**Acceptance test**: no direct executable test; tracked qualitatively via the Phase-1-onward exit gates requiring `cs why` to explain every blocked Mission from structured projections (master-prompt section 14 invariant 27), rather than from prose or shell-script classification logic.

### F2. Append-only status logs were already identified, in Firstmate's own documentation, as the wrong primitive for current state

**Preconditions**: Firstmate's crew status files are append-only logs of wake events.
**Observed behavior**: Firstmate's own `architecture.md` (per the grounding research) explicitly documents this as a known defect: an append-only wake-event log can bury an earlier, still-open needs-decision or blocked status underneath later, unrelated appended entries, requiring a separate "cursor-folded open decisions" re-derivation pass layered on top just to recover current state from the log.
**Expected behavior**: a Question's or blocker's current status should be a single, directly queryable current-state field, not something that must be re-derived by folding over a log.
**Data or work at risk**: a genuinely open, blocking decision could be effectively invisible, buried under later unrelated log entries, until the fold-recovery pass specifically looked for it.
**Manual intervention**: a dedicated recovery/fold mechanism was built specifically to compensate for this.
**Architectural cause**: using an append-only log as the primary representation of something that is actually current, mutable state.
**New invariant**: this is the direct, first-party (documented by the prior system's own authors) justification for master-prompt section 10.5's Question and section 10.3's Mission blocker being real current-state rows with a `status` field, and for master-prompt section 4.4's rule that "projections are operational truth; events are audit history, not the primary rehydration source."
**Acceptance test**: master-prompt section 14 invariant 24 ("events are audit history; projections are operational truth"), verified by ensuring no code path ever needs to replay or fold the `domain_event` table to determine a Question's or Mission's current status; that status must always be readable directly from its projection row.

### F3. A sustained multi-hundred-commit stream of liveness-class bugs

**Preconditions**: the shell/pane/file-based coordination model described in F1/F2.
**Observed behavior**: of the most recent roughly 300 commits inspected, at least 45 were fixes for stale locks, false watcher-down alarms, orphaned processes left behind at teardown, dead-peer detection races, session-lock ownership races, remote polls blocking session startup, truncated session-start digests losing fleet state, and tmux/pane liveness hardening across multiple harnesses. This same pattern continued directly into the legacy Consigliere repository (see C1 through C5 above), which inherited the same coordination model rather than a different one.
**Expected behavior**: the rate of liveness-class bugs (a process's aliveness being confused with a task's correctness) should trend toward zero because the underlying state model makes the confusion structurally impossible, not because each new instance of it is individually patched.
**Data or work at risk**: cumulative engineering time and the standing risk that any given liveness bug of this shape is currently unpatched.
**Manual intervention**: each of the 45+ commits represents a separate manual fix.
**Architectural cause**: the base assumption, present at Firstmate's origin and never revisited, that shell-process or terminal-pane liveness is an adequate proxy for task or supervision liveness.
**New invariant**: master-prompt section 14's invariants 11 and 12 ("output silence alone never marks an Attempt lost," "process-inventory evidence is required for loss classification") directly target this failure class; consigliere-next's runner protocol (master-prompt section 8) requires actual process-group verification, not output-silence heuristics, before any Attempt is classified as lost.
**Acceptance test**: master-prompt section 17 tests 5 and 6 (no output for a long interval produces inspection, not loss; sleep for two simulated hours causes zero false losses), which are the direct structural descendants of this entire bug class.

## Cross-cutting observation

Every incident above, across all four source systems, traces back to one of exactly two root causes: (1) treating a process's, a pane's, a file's, or an external tracker's liveness/content as if it were durable, authoritative state, when it was never designed to be; or (2) enforcing a correctness rule only as prose/convention rather than as a structural mechanism a lower-trust principal cannot violate. Master-prompt sections 4.2, 4.4, 25.2, and the entire three-principal authority model in section 5 are direct, evidence-backed responses to these two root causes, not speculative hardening against imagined threats.
