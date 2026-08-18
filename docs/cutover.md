# Cutover runbook

This document formalizes master-prompt section 8 (locked architectural direction: one harness and one lane through cutover) and section 23 (Phase 8 per-project pilot cutover) into an actionable runbook.
It exists so that cutover is executed as a checklist against durable evidence, not as a judgment call made in the moment.

## Why this is a runbook and not a design doc

By the time cutover is attempted, the architecture is already built and hardened (Phases 0-7 complete, section 22's exit gate satisfied: every P0 invariant has an automated failure test).
Cutover risk at that point is not "does the design work," it is "did we actually verify each precondition on this specific Project before flipping dispatch." A runbook forces that verification to be explicit and checkable rather than assumed.

## Do not build full shadow mode

Section 23 states this directly: do not parse legacy wake queues, monitor PIDs, status folds, or pending-reply internals merely to simulate parity with the old system before cutover.

The reason is not caution for its own sake. The Firstmate grounding research already in evidence for this rewrite found approximately 52,558 lines of bash across 134 scripts, with the ten largest files alone (`fm-spawn.sh` at 2,776 lines, `fm-teardown.sh` at 2,549, and eight others) totaling nearly 15,000 lines, almost entirely in the supervision/spawn/wake/status category rather than product features. Of the most recent roughly 300 commits in that lineage, at least 45 were `fix` commits directly addressing liveness, wedge, race, staleness, or orphan-process bugs. The `state/` directory held dozens of loose per-task sidecar marker files with no schema and no transactionality (`.hash-default_w*`, `.seen-*_turn-ended`, `.stale-default_w*`, and similar), and the architecture doc itself named append-only status logs as a known defect: "Crew status files are append-only wake-event logs, not current-state fields... can bury an earlier still-open needs-decision/blocked under later unrelated appends."

Building a shadow-mode parity layer against that state model means writing new code whose job is to faithfully reproduce the failure modes this rewrite exists to eliminate. Parity with a system that has append-only logs mistaken for state, marker files mistaken for authority, and a sustained multi-year stream of liveness-class bugs is not a safety net; it is importing the same bug surface at one remove. Section 25.3's prohibition on speculative abstraction applies here directly: a shadow-parity layer is scope the rewrite does not need, built to satisfy anxiety about the cutover rather than a real correctness requirement. The actual safety net is the manual cutover checklist below plus the rollback semantics in section 5, both of which operate on durable state the new system already owns.

## Pilot project selection criteria

Choose the pilot Project against these criteria, in order:

1. Noncritical: a Project where a mishandled Mission, a lost Question, or a botched merge would not cause meaningful harm if something goes wrong during the pilot.
2. Low concurrency: a Project that realistically has at most one active line of work at a time today, since V1 supports exactly one active Mission per Project (section 4.10).
3. Single harness already: a Project whose current work is already compatible with the one harness selected for V1 (section 4.10), so the pilot does not simultaneously test harness compatibility and cutover mechanics.
4. Bounded in-flight work: a Project with few or no legacy tasks currently in progress, minimizing the classification work in step 4 of the pilot sequence below.
5. An engaged boss: the boss must actually exercise the Question/AFK/Made-decision/delivery flows during the pilot; a pilot nobody interacts with proves nothing.

## Pilot sequence

Each step below is a checklist item. "Evidence" is what must be true and observed, not merely attempted, before moving to the next step.

1. **Choose one noncritical Project.** Evidence: the Project satisfies the selection criteria above; the choice is written down with the reasoning.
2. **Pause legacy dispatch for that Project.** Evidence: the legacy system's dispatch mechanism for this Project is confirmed stopped (no new legacy task can be spawned for it) by inspection of the legacy control surface, not by assumption.
3. **Confirm no legacy Agent is actively writing.** Evidence: a live check (process listing, pane inspection, or the legacy system's own status surface) shows zero active legacy Attempts against this Project's repository at the moment of pause.
4. **Classify existing legacy tasks** into: finish under legacy, cancel, import manually as a new Mission, or quarantine. Evidence: every legacy task for this Project has an explicit disposition recorded; none are left ambiguous.
5. **Import Project repository identity and policy.** Evidence: a Project row exists in consigliere-next with the correct `repository_path`, `repository_url`, `default_branch`, `dispatch_policy`, `validation_policy`, and `integration_policy` (section 10.1), verified by reading the row back, not by trusting the import command's exit code alone.
6. **Create the trusted mirror.** Evidence: `trusted/projects/<project-id>.git` exists, is a bare repository, and its default-branch ref matches the real repository's current head SHA exactly.
7. **Reconcile existing branches and PRs.** Evidence: every open PR and non-default branch relevant to this Project is enumerated and its disposition (left alone, superseded, tracked) is recorded; no PR is silently orphaned.
8. **Enable the new internal Mission backlog** for this Project. Evidence: `cs mission create` succeeds against this Project and the resulting row is visible via `cs missions`.
9. **Run a controlled Mission** end to end: create, authorize, execute, checkpoint, complete. Evidence: the Mission reaches a terminal `completed` phase with a durable artifact and an audit trail, per the Phase 3 exit gate (section 18).
10. **Test Question flow.** Evidence: a real or deliberately triggered Question is opened by an Attempt, persisted before acknowledgement, and answered through the privileged boss channel, matching the Phase 4 kill-everything test's shape (section 19) but run for real on this Project.
11. **Test AFK return.** Evidence: `cs away`, a Question or blocker arising while away, and `cs return` correctly surface the durable digest with the Question intact, per section 19's AFK model.
12. **Test daemon restart.** Evidence: the daemon is stopped and restarted mid-Mission (or between Missions) and the Mission/Attempt/Question state is unchanged and correctly reconciled afterward, per Phase 1/2 invariants.
13. **Test a Made decision.** Evidence: a `needs_decision` Gate outcome is produced for real validation work on this Project, the Question is answered, and a rerun against the same input SHA proceeds, per section 20.
14. **Test exact-SHA delivery.** Evidence: a real Mission reaches privileged push, PR creation or reconciliation, and boss-authorized merge with server-side expected-head-SHA enforcement, per section 21.
15. **Document incidents and corrections.** Evidence: any deviation from expected behavior during steps 9-14 is written down with what was wrong and what was fixed, before declaring the pilot successful.
16. **Run multiple real Missions before expanding** to a second Project. Evidence: at least a small number of real, boss-initiated Missions (not synthetic test Missions) have completed successfully, with no open incident from steps 9-15 still unresolved.

## Rollback semantics

Rollback is available at any point in the pilot sequence, but it is not free reversal.
Rollback means:

- Stop new-system dispatch for the pilot Project immediately.
- Preserve the current new-system database and all artifacts exactly as they are; do not delete or reset consigliere-next state as part of rolling back.
- Manually handle any branches or PRs the new system already created; these are real external mutations and must be resolved by a human, not silently abandoned.
- Explicitly transfer Project authority back to the legacy system, recorded the same way the original pause in step 2 was recorded.
- Never allow both the legacy scheduler and consigliere-next to dispatch against the same Project simultaneously, under any circumstance. Dual dispatch is the one rollback failure mode that can cause real, hard-to-reverse damage (conflicting branches, duplicate PRs, races on the same workspace).

Because of the external mutations a Mission can already have caused by the time rollback is invoked (pushed branches, opened PRs, posted comments), rollback should never be described to the boss as "fully reversible." State plainly what has already happened externally and what remains to be manually resolved.

## Cutover exit gate

The pilot must prove, through real use and not simulated load, every item in this list, cross-referenced against the master prompt's Final Definition of Done (section 27):

- The boss can leave without a live root conversation (section 27, first bullet; proven by pilot step 11).
- Every acknowledged Soldier Question is durable (section 27; proven by pilot step 10).
- At least one best-effort notification path exists (section 27; exercised during pilot steps 10-11).
- No human wait retains an Agent or validator (section 27; proven by pilot steps 10 and 13).
- Mission state survives lost Attempts (section 27; proven by pilot step 12, and by any real Attempt loss encountered during steps 9-16).
- Coordinator crashes do not kill unrelated running work (section 27; a Phase 2/7 property that the pilot should not need to re-trigger deliberately, but must not violate if it happens incidentally).
- Daemon loss terminates Agent process groups safely (section 27; proven by pilot step 12 if an Attempt happens to be active during the restart, otherwise carried over from the Phase 2/7 automated test evidence).
- Every resumable state is an imported commit SHA (section 27; proven by pilot steps 9 and 14).
- Model sessions cannot grant boss authority (section 27; carried over from Phase 4/7 automated evidence, per the threat-model.md T1/T2 mitigations).
- Repair budgets span SHAs and terminate loops (section 27; proven if pilot step 13 involves more than one repair round).
- Made exits on human decision and validation reruns deterministically after a Decision (section 27; proven by pilot step 13).
- Delivery uses a trusted mirror and merge uses exact-SHA server-side enforcement (section 27; proven by pilot step 14).
- Every wait state is explainable through `cs why` (section 27; exercised informally throughout the pilot whenever a Mission is not runnable).
- Poison data quarantines instead of crash-looping, and sleep/wake do not cause false losses (section 27; carried over from Phase 1/2/7 automated evidence, not expected to be deliberately re-triggered during the pilot).
- Backup and restore work (section 27; carried over from Phase 1/7 automated evidence).
- One real Project has completed a sustained pilot, and the legacy Bash runtime is no longer required to supervise that Project (section 27, final two bullets; this is the pilot's own success condition, proven by pilot step 16).

Do not declare cutover complete for a Project until every item above is checked against real evidence gathered during that Project's own pilot, not inferred from another Project's pilot or from the automated test suite alone.
Automated tests prove the mechanism works in general; the pilot proves it worked for this Project, with this boss, under real conditions.
