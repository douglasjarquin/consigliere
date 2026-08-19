# Mission state machine

## Purpose

A Mission is durable authorized software work.
It is the unit that a boss authorizes, that survives every Attempt, Agent, coordinator, daemon, and machine restart, and that a MissionCoordinator rehydrates purely from projections.
A Mission's phase captures coarse lifecycle position only.
Fine-grained waiting conditions (a specific open Question, a specific failing Gate, a specific missing dependency) live in Mission blocker rows, not in additional phases.
This keeps the phase enum small and keeps "why is this Mission not running" a query over blockers rather than a growing set of ad hoc phase values.

## States

- `draft` - the Mission has been proposed (by a model, by intake, or by the boss) but has not yet been authorized. No workspace exists. No Attempt may start.
- `awaiting_authorization` - the Mission is fully specified (objective, scope, acceptance criteria) and is waiting on a boss `work` Authorization. This is a distinct state from `draft` so that "proposed but incomplete" and "proposed and ready for a decision" are not conflated in `cs why`.
- `authorized` - a boss `work` Authorization has been granted and recorded against this Mission. The Mission has not yet produced a workspace or an Attempt.
- `active` - at least one Attempt has been scheduled or is running against this Mission's current checkpoint. A Mission can cycle between `active` and having open blockers many times; blockers do not change the phase, they gate whether the Mission is runnable while remaining `active`.
- `ready_for_review` - validation (Gate set required by the Mission's validation policy) has passed at the current checkpoint SHA and the Mission is waiting to be prepared for delivery, or has been prepared and is waiting on the boss to look at it.
- `awaiting_integration_authorization` - delivery has produced a PR/head SHA and the Mission is waiting specifically on a boss `integration` Authorization naming that exact PR and head SHA.
- `integrating` - an `integration` Authorization has been granted and the Integration Coordinator is executing the exact-SHA merge sequence (push from trusted mirror, PR reconcile, CI projection re-check, merge call, post-merge reconciliation).
- `completed` - the Mission's work has been merged (or otherwise delivered per its integration policy) and no further Attempts may start against it.
- `failed` - the Mission has exhausted its retry/repair budgets, or has hit a terminal incident, and requires explicit boss or project decision to proceed; it does not auto-retry further from this phase.
- `canceled` - the boss (or an authorized policy) ended the Mission before completion. Distinct from `failed`: cancellation is a deliberate stop, not an exhausted-budget stop.
- `superseded` - a newer Mission has replaced this one (same objective re-authorized, or scope split/merged). The prior Mission's open Questions and Attempts are deterministically resolved per the supersession rule (see Failure-mode traceability below).

## Transition table

| From | To | Trigger | Guard | Side effects |
|---|---|---|---|---|
| (none) | `draft` | `mission.create` command | none | Mission row inserted; `mission.created` event |
| `draft` | `awaiting_authorization` | `mission.submit_for_authorization` | objective, scope, acceptance_criteria all non-empty | `mission.submitted` event |
| `draft` | `canceled` | `mission.cancel` | boss principal | `mission.canceled` event; any draft blockers closed |
| `awaiting_authorization` | `authorized` | boss grants `work` Authorization | Authorization principal is boss, Authorization scope is `work`, Authorization targets this Mission | Authorization row inserted; `mission.authorized` event; `authorization_id` set on Mission |
| `awaiting_authorization` | `draft` | `mission.request_changes` | any principal with edit rights | `mission.returned_to_draft` event |
| `authorized` | `active` | MissionCoordinator schedules first Attempt | workspace can be created or already exists; GlobalScheduler grants a slot | Workspace row created/reused; Attempt row created in `planned`; `mission.started` event; `started_at` set |
| `active` | `active` | Attempt completes, fails, is lost, or is superseded; new Attempt is scheduled | retry/repair budget not exhausted | new Attempt row; ledger updated if this was a repair round |
| `active` | `ready_for_review` | required Gate set reaches `passed` at current checkpoint SHA | all Gates in Mission's validation_policy are `passed` for the same input SHA | `mission.ready_for_review` event |
| `ready_for_review` | `active` | new checkpoint SHA invalidates a passed Gate, or boss requests further work | at least one required Gate is no longer valid for the new SHA | Gate(s) transition to `invalidated`; new Attempt scheduled |
| `ready_for_review` | `awaiting_integration_authorization` | delivery produces a PR and head SHA | delivery sequence (Section 13) has reached "ready for boss review" | `mission.awaiting_integration` event |
| `awaiting_integration_authorization` | `integrating` | boss grants `integration` Authorization | Authorization principal is boss, scope is `integration`, target_pull_request and target_sha match current delivery state exactly | Authorization row inserted; `mission.integration_authorized` event |
| `awaiting_integration_authorization` | `active` | base branch or PR state moved out from under the pending authorization | reconciliation detects target_sha no longer matches remote head | Authorization invalidated; blocker of kind `validation` or `external_service` opened; Mission returns to `active` for revalidation |
| `integrating` | `completed` | Integration Coordinator confirms merge at expected head SHA | server-side expected-SHA compare-and-swap succeeded, or reconciliation proves an equivalent already-merged state | `mission.completed` event; `completed_at` set; `current_delivery_sha` set to merged SHA |
| `integrating` | `awaiting_integration_authorization` | merge attempt fails because remote head moved (force-push race) | server rejected the expected-SHA merge | Authorization revoked; `mission.integration_race_detected` event; blocker opened |
| any non-terminal | `failed` | repair/retry budget exhausted, or terminal incident recorded | ledger counters exceed policy limits, or an Incident row references this Mission with severity terminal | `mission.failed` event; `terminal_reason` set; open Questions handled per supersession rule |
| any non-terminal | `canceled` | boss cancels | boss principal | `mission.canceled` event; active Attempt(s) checkpoint-and-terminate; workspace released |
| any non-terminal | `superseded` | a replacement Mission is authorized for the same scope, or the boss explicitly supersedes | replacement Mission row exists with a `replaces_mission_id` referencing this Mission (forward pointer, mirroring Attempt's `retry_of_attempt_id`; no reverse-pointer column on this row -- see Decision below) | `mission.superseded` event; every open Question and active Attempt for this Mission resolved per the supersession rule |
| `failed` | `active` | boss or project policy grants a decision that raises the budget or authorizes a fresh attempt | a Decision row of scope `mission_finding_waiver` or `project_policy_override` references this Mission's blocking incident | ledger not reset, only the specific blocking condition cleared; `mission.resumed_after_decision` event |

## Terminal states

`completed`, `canceled`, and `superseded` are hard-terminal: no Attempt may ever start against a Mission in these phases, and no transition leaves them.
`failed` is soft-terminal: it does not auto-retry, but an explicit Decision (never an automatic timer or retry loop) can move it back to `active`.
This distinction exists because §11's repair budgets must be able to stop a Mission without requiring the boss to formally cancel work that might still be worth resuming once a human looks at it.

## Invariants enforced by this state machine

- **Invariant 1** (a Mission survives every restart): the phase and all fields above live in the `missions` projection table, never in coordinator memory; MissionCoordinator rehydrates by reading this row, not by replaying events.
- **Invariant 8** (uncommitted files are not durable checkpoint state): `current_checkpoint_sha` only advances via the Attempt checkpoint-import sequence (see attempt.md), never from an Attempt's raw workspace state.
- **Invariant 16/17** (repair budgets span SHAs, new Gate creation cannot reset them): the `active -> active` retry transition and the `ready_for_review -> active` invalidation transition both consult the Mission validation ledger, a row keyed by `mission_id` + `gate_type` that is never reset by this state machine, only incremented.
- **Invariant 18** (integration authorization is tied to exact PR and head SHA): the `awaiting_integration_authorization -> integrating` guard checks `target_pull_request` and `target_sha` match exactly; the `integrating -> awaiting_integration_authorization` transition exists specifically to handle the case where they stop matching.
- **Invariant 26** (every non-runnable Mission has a deterministic blocker explanation): phase alone never fully explains why a Mission is not running; every non-`active`-with-zero-blockers state has either a phase-level reason (e.g. `awaiting_authorization` means "no work Authorization yet") or an open blocker row that `cs why` reads directly.
- **Invariant 29** (superseding a Mission deterministically handles its open Questions): the `-> superseded` transition is defined once, with one deterministic side effect, rather than being handled ad hoc by whatever caused the supersession.

## Failure-mode traceability

- Legacy Consigliere's `cs-made-run-lib.sh` `cs_made_run_is_gate_parked` behavior describes a Made run parked at `awaiting_approval`/`fix_review` holding a fleet slot indefinitely until `cs-teardown.sh` explicitly concludes it.
This is exactly the shape the `ready_for_review -> active` and Mission validation ledger design is meant to make structural rather than manual: a Gate's `needs_decision` outcome must map to a Mission blocker that `cs why` can explain without anyone having to run teardown to discover the Mission is stuck.
- Legacy Consigliere's SEC-01/SEC-02 incidents (a soldier's status text laundered into a trusted supervision envelope) is why Mission-level Authorizations require `granted_by_principal` to be checked as the *boss* principal specifically at the `awaiting_authorization -> authorized` and `awaiting_integration_authorization -> integrating` transitions, not merely "some principal recorded an approval." A model-advisory recommendation can populate every other field on a Mission; it can never itself cause these two transitions.
- Made's confirmed forward-referenced CLI (`cs-made-lib.sh` calling `made axi status`/`made axi abort` before those subcommands existed in Made's own `cmd/made/main.go`) is why the `ready_for_review -> awaiting_integration_authorization` transition's guard is defined against Made's actual managed-mode contract (see `docs/protocols/made-managed-mode.md`), not against an assumed or hoped-for CLI surface; a Mission must never advance phase based on a integration mode that does not exist yet.
- Symphony's `:one_for_all` AgentRuntimeSupervisor (an Orchestrator crash kills every in-flight agent Task alongside it) is why this state machine defines Mission phase and Attempt lifecycle as separately durable: a MissionCoordinator crash and restart must rehydrate this same phase value from the row without having caused any `active -> active` transition itself, and without terminating whatever Attempt was running.

## Open questions carried forward (not resolved here)

- Whether `awaiting_integration_authorization -> active` (base moved) should be an automatic reconciler-driven transition or must always go through an explicit Decision; this document assumes automatic reconciliation is safe because it only ever narrows authority (revokes a stale Authorization), never grants one.

## Decision (2026-08-19): no `superseded_by` reverse-pointer column

No dedicated `superseded_by` foreign key is added to the Mission table.
This overrides this document's own earlier recommendation ("add it directly to avoid a reverse-lookup at query time") in favor of the simpler schema: `replaces_mission_id` on the *replacement* Mission's row (see the transition table above) is the only stored pointer.
"What superseded this Mission" is answered by a reverse lookup (`WHERE replaces_mission_id = this_mission.id`), not a second stored column.
If `cs why`'s query performance on that reverse lookup ever becomes a real problem, add the column then, backed by an actual measurement, rather than paying the schema/write-path cost now for a query pattern that has not yet been shown to need it.
