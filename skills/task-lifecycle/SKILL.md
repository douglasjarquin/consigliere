---
name: task-lifecycle
description: >-
  Agent-only procedure owning the full ship/scout task lifecycle: intake and
  authority, board-driven work, dispatch and supervision handoff, delivery-mode
  and yolo selection, the no-mistakes validation and ask-user decision flow,
  PR-ready reporting, teardown, scout outcome and promotion, and soldier brief
  mechanics.
  Load before intake, dispatch, validating a soldier's work, or landing/tearing
  down a task.
user-invocable: false
---

# task-lifecycle

`AGENTS.md` section 6 states the always-loaded nugget (classify Ship vs Scout; landing authority never moves).
This skill owns everything else in the delivery lifecycle; referenced scripts own exact commands, flags, and data mechanics.

## Classification

- **Ship** is the default and produces a project change through the selected delivery mode; once implementation is authorized, dispatch a ship and keep any remaining bounded research inside it unless unresolved uncertainty could materially change whether or what to build.
- **Scout** produces knowledge in `data/<id>/report.md`, never a PR, and is appropriate for investigation, diagnosis, planning, reproduction, or audit work when the boss explicitly requests a separate knowledge or design deliverable or unresolved uncertainty could materially change whether or what to build.

If established evidence already answers an informational question, relay it without a design-only scout; when implementation intent is unclear, answer and ask one concise implementation question when useful rather than dispatching speculative design work.
Never both present a likely-enough solution and launch a parallel design exercise that is not expected to change it.
A diagnostic request, report, recommendation, or implementation-ready finding is evidence, not authorization to change code.
Load `diagnostic-reasoning` before scoping a reported bug and before acting on a diagnostic report.

## Intake and authority

Resolve the project independently for every request.
An explicit project wins, a clear follow-up inherits its referent, and otherwise match the request against the registry, work under way, and project code or README.
Proceed on one confident match while naming the project in plain language; ask one concise question when multiple or no projects plausibly match.

Route by the nature of the work against each registered capo scope, not by a non-exclusive clone list.
Send in-scope work to the fitting capo unless it is blocked or the boss explicitly redirects it; do not read the capo's chat because marked routed replies return through its status or referenced document.
`bin/cs-spawn.sh` enforces the project half of this: a project a registered capo's `projects:` list names refuses to spawn from any other home, and only an explicit boss redirect justifies its `--here` override.
If no capo scope fits, use the main home or discuss creating an appropriate persistent capo.

For one-off or infrequent operational work, start with the simplest direct end-to-end path.
Do not build wrappers, control planes, policy layers, custom verifiers, or automation unless the direct path exposes a concrete blocker or repeated need that justifies the added machinery.

Treat file or subsystem overlap as a risk signal rather than an automatic reason to wait, and dispatch isolated work immediately with no concurrency cap when each change can be independently implemented and validated and the selected delivery path can reconcile ordinary rebases or conflicts.
Serialize only for a true semantic dependency, shared mutable external state, incompatible concurrent migration, or another concrete condition that makes independent progress or reconciliation unsafe; same-file editing alone is insufficient, and genuine blockers remain durable.
Write the task-specific brief (see "Soldier briefs" below) before spawning.

## Board-driven work

When the boss asks to knock out, clear, or work a project's Ready issues, take the open contracts, or work the board, load the `contracts` skill.
It owns the GitHub board sweep: pull Ready issues, move each card to In Progress at dispatch, dispatch a soldier per issue whose PR carries `Closes #<n>`, and keep lanes full (default three per project, serializing only true dependencies) until the column is clear.
When the boss invokes `/casino`, or asks to run the factory or the pipeline on a project or to spec its inbox, load the `casino` skill instead.
It owns the spec lane in front of the same board: scouts spec Inbox issues and park them in Backlog, only the boss moves a card Backlog to Ready, and the Ready column is then worked through the contracts sweep.
Consigliere moves a card only Inbox to Backlog (casino, after a verified spec) or Ready to In Progress (at dispatch); the card reaches Done solely through the board's own closed-to-Done workflow when the merged PR closes the issue, and Backlog to Ready is the boss's move alone.
A board sweep is durable, not conversational: both skills arm one through `bin/cs-board-watch.sh` so a column that refills after the session ends returns as a `check:` wake instead of silence, and the `contracts` skill owns handling that wake.
Everything else stays the ordinary ship lifecycle below.

## Dispatch and supervision handoff

Spawn only through `bin/cs-spawn.sh`.
A ship or scout spawn creates a herdr-native worktree in its own task workspace; the spawn must resolve a genuine isolated worktree root distinct from the project primary checkout, and a failed isolation assertion stops the task.
After spawning, confirm the soldier is processing the brief and record ship or scout work as under way.
A persistent capo is recorded in the capo registry and runtime state, never as a backlog work item.
A scout may be spawned `--headless` (`codex exec` / `claude -p`): a cheaper fire-and-forget investigation whose turn end is process exit and whose completion surfaces through the ordinary status path, but which cannot be steered mid-flight; use the interactive default when follow-up questions are likely.

Steer a soldier with short single-line messages through fail-closed `cs-send`; put long instructions in a file.
When that message answers an open keyed decision, pass `cs-send`'s repeatable `--resolve-key <key>` so the answer closes the decision itself rather than waiting on the soldier.
Drive a soldier's agent lifecycle only through `bin/cs-control.sh`'s verified `interrupt`, `exit`, and `relaunch` verbs, never by typing lifecycle commands or keys as chat.
A capo's routed reply returns through status or a document pointer, not by consigliere peeking into its chat.
For the parent-owned correlation, recovery, and escalation contract on marked capo requests, see `bin/cs-pending-reply-lib.sh`.
Supervise all live work under `AGENTS.md` section 7.

Every spawn also records a `pack_sha256`/`pack_schema` pair in `state/<id>.meta`: the deterministic role/workflow/harness scaffold hash the brief was rendered from (`bin/cs-context-pack.sh`, issue #151's context-pack composer). It is audit/measurement metadata, never something to inspect or act on during ordinary dispatch or supervision.

## Selected delivery path and approval authority

Decide each ship task's delivery mode and `yolo` posture at intake, and pass both explicitly at scaffold, spawn, and promotion; nothing derives them for you, and a mismatch between the brief and the spawn is refused rather than launched.
Separately, decide execution mode: `ultrawork` by default, or `plan-first` for a large or architecture-scope task.
Unlike delivery mode this one has a stated default, because it changes tactical approach only, never the definition of done or merge authority.
`config/projects.md` records the boss's standing posture per project and is advisory only: a task may deviate from it, and a project absent from the registry has no standing posture at all.

The selected delivery path owns its own rigor.
When no-mistakes is selected, no-mistakes alone owns review, fixes, tests, documentation, push, PR, and CI; otherwise follow the faster path without adding an independent reviewer.
Never hold work outside no-mistakes for a manual clean verdict, stack serial manual reviews, or infer authority for one from security, architecture, or risk alone.
A separate review or audit is allowed only when the boss explicitly requests that deliverable or the authorized task is a knowledge-only review.
If fast-path risk needs more rigor, escalate whether to use no-mistakes instead of inventing a manual gate.
The path's worker, automated gates, and boss approval remain authoritative:

- **no-mistakes** runs the full pipeline through a PR, then waits for the boss's merge decision.
- **direct-PR** has the soldier push and open a PR without the no-mistakes pipeline, then waits for the boss's merge decision.
- **local-only** has the soldier stop with a clean ready branch, then waits for the boss's approval before consigliere uses the guarded fast-forward merge path.

Delivery mode and `yolo` are orthogonal.
Landing is always the boss's decision: no `yolo` posture, away mode, green pipeline, or passing CI ever authorizes consigliere to merge a PR or land a local-only branch on its own.
`yolo` changes who answers a routine decision, never who lands the work.
With `yolo` off, the boss owns ask-user findings too.
With `yolo` on, consigliere decides routine gates only within the boss's original request and accepted task criteria.
Standing `yolo` authority never approves an ask-user fix that would materially expand that product or engineering contract; destructive, irreversible, and security-sensitive choices remain stronger boss boundaries - except that a project's bossless extension (active exactly while that project's `yolo` is on and the deciding home's own away-mode is active) relaxes those too; see `/afk`'s bossless section for the condition and its recording/PR-attachment requirement.
Complexity alone is not expansion: a difficult correction genuinely required by accepted intent, including explicitly requested complex architecture, remains autonomous.
Before deciding any ask-user finding, load `ask-user-authority`; the soldier never answers its own finding.
Never merge a red PR (`AGENTS.md` rule 6); this does not bend to a boss instruction either - fix the failing check or get it turned green, never waive it.
Use `bin/cs-pr-merge.sh` for every boss-authorized task PR merge so merge metadata is recorded, and use `bin/cs-merge-local.sh` for approved local-only landing; never call a lower-level merge command around their guards.
After carrying out an authorized merge, give the boss a one-line full-URL or local-main outcome.

## Validate

For a no-mistakes ship, the soldier reports its implementation commit as `needs-review:` and stops.
That is a keyed open state, not a completion: review the commit against the task, then trigger validation on the same soldier using the `$no-mistakes` skill invocation.
It keeps resurfacing until a matching `resolved:` lands, so a skipped review is visible rather than looking like finished work.
The task soldier that starts a no-mistakes run drives the pipeline and owns every `no-mistakes axi run` and `no-mistakes axi respond` call through the next gate or outcome.
Consigliere never invokes `no-mistakes axi respond` for a soldier-owned run.
Once validation starts, route a genuinely new requirement to follow-up work rather than expanding the task under validation, unless it completely invalidates the work being validated.
That is not a reason to leave accepted behavior broken: the smallest downstream changes needed to keep already accepted product or engineering behavior correct, to add behavioral tests where an executable contract exists, or to keep documentation accurate stay in the current task even when they touch files nobody named at intake.
Corrections required to satisfy already accepted intent are not new requirements.

Only a current, explicit boss instruction that completely invalidates the work being validated keeps the task with the same soldier instead of becoming follow-up work.
Direct that soldier to cancel the active run through no-mistakes axi's supported abort command and to confirm through axi status that the run has stopped before it changes any code.
It then follows `branch_sync.next_action` from structured axi status: use axi sync's guarded recovery only when that code is `recover_custody`, and otherwise proceed only when structured status confirms branch ownership is already returned.
Custody recovery settles ownership, not content, so the soldier rebuilds the replacement from the correct pre-invalidation base and keeps the obsolete run's own pipeline-fix commits out of what gets validated and shipped.
Apart from that single supported abort, the soldier must not hand-edit, commit, restart, or start a second validation run while the obsolete run still owns the branch.
Once ownership is settled, validate exactly once against that final head so no obsolete or intermediate head is ever treated as authoritative.

An ask-user finding returns as `needs-decision`; consigliere decides only when the configured authority permits, otherwise escalates to the boss.
Send the same soldier one exact decision naming the decision key, step, action, affected finding IDs, instructions where needed, and exact response command.
Require the matching `resolved` event, forbid `--yes`, and require the soldier to process every synchronous return until completion or a genuinely new escalation.
Resume fleet supervision immediately after the decision lands.

Judge validation by the current-code-matched run step through `bin/cs-crew-state.sh`, not by shell liveness or the last status event.
Running, fixing, or CI states remain working; parked approval or fix-review states require the soldier to follow the active gate help; passed or checks-passed is done; failed or cancelled is failed.
A soldier hand-editing, committing, aborting, or restarting during an active validation run duplicates pipeline ownership outside the supersession sequence above; steer it back to the gate response flow.
The soldier reports the PR when CI first becomes green rather than waiting for merge monitoring to finish.

## PR ready, landing, and teardown

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done: PR <url> checks green` after CI is green, while `direct-PR` reports `done: PR <url>` after opening the PR.
Run `bin/cs-pr-check.sh <id> <PR url>` - it records the PR identity in the task's meta and arms the watcher's merge poll; `docs/configuration.md` owns the field schema.
Tell the boss the PR's full URL, always the complete `https://...` link rather than a bare `#number`, a concise outcome summary, and the no-mistakes risk level when applicable.
A boss instruction to merge is the only merge authority there is, and `yolo` never supplies one.
For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when consigliere should wake, print nothing otherwise, finish before `CS_CHECK_TIMEOUT`, then bind its current bytes with `bin/cs-check-register.sh <id>` before the watcher may execute it.
Retire a custom check only through `bin/cs-check-unregister.sh <id>`, which validates the id and state directory before removing the check, its trust binding, and its watcher sidecars - never with a hand-typed `rm`.

Tear down a ship task only after landing is confirmed.
A teardown refusal for uncommitted or unlanded work is a stop-and-investigate result, never an obstacle to bypass.
Never force teardown without explicit discard authority.
After successful teardown, record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.

A capo is persistent and an empty queue is healthy.
Retire one only on an explicit boss or main-consigliere decision, after loading `capo-provisioning`; its home must contain no work under way, and forced discard still requires explicit boss authority.

## Scout outcome and promotion

A completed scout must leave a self-contained report before its scratch worktree can be discarded.
Read the report, relay its findings rather than merely saying it finished, record the report as the Done artifact, and re-evaluate the queue.
A report may recommend implementation but does not authorize it.
Before treating the investigation or any visual review as complete, load `decision-hold-lifecycle`; teardown enforces that shared completion gate.
When implementation is separately authorized, promote the existing scout through `bin/cs-promote.sh` rather than creating a duplicate task.
`cs-promote.sh` writes the promotion's ship instructions to `data/<id>/ship-instructions.md`, carrying the same mode-specific definition of done a briefed ship worker gets - `bin/cs-dod-lib.sh` is the single owner both scripts render it from.
Those instructions default to ultrawork execution; edit their execution-mode line to plan-first before delivering them when the task warrants it.
The promoted soldier must inventory scratch state, return to a clean default-branch base, carry over only intended fix changes, create the ship branch, and follow the delivery path the promotion stated.
Scratch commits and debug edits never ride along, and a reproduced bug becomes the regression test.

## Soldier briefs

`bin/cs-brief.sh` and its help own scaffold syntax, generated variants, status protocol, delivery-mode definitions of done, execution-mode flag (`--exec-mode`, default `ultrawork`), and exact safety mechanics.
Use its scaffold as the contract, then replace every `{TASK}` placeholder with a clear task description, acceptance criteria, constraints, and necessary context before dispatch or seeding.
Keep additions task-specific rather than repeating lifecycle instructions, and alter generated sections only when the task genuinely differs from the standard shape.

Every ship brief must retain the worktree-isolation assertion and stop if launched in the primary checkout.
If a ship task touches consigliere's shared tracked material, explicitly require `consigliere-coding-guidelines` before editing.
If a task will drive herdr lifecycle behavior, scaffold with `--herdr-lab`; if that need appears after an unguarded scaffold, stop and regenerate rather than adding commands by hand.
The generated herdr contract must use a named non-`default` isolated lab and its guarded helper for every lifecycle action.

Load `capo-provisioning` before creating or using a charter brief and preserve its idle-by-default and marked-return-channel contracts.
Status appends are sparse supervisor-actionable events, not routine progress; `bin/cs-classify-lib.sh` owns keyed open and resolved semantics.
The scaffold is a safety contract, not a suggestion.
