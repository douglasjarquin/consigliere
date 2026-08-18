# Workspaces and the Git trust boundary

This document formalizes how consigliere-next isolates Agent-controlled Git repositories from privileged delivery operations, and how a checkpoint becomes durable.
The governing rule is simple to state and easy to violate in the details: privileged Git operations never run from an Agent-controlled repository, and the only durable representation of an Attempt's work is a committed SHA that the daemon has imported into a trusted mirror it exclusively owns.

## Why this boundary exists: SEC-01 and SEC-02

Phase 0 grounding in the legacy Consigliere repository (`docs/operational-input-provenance.md` at commit `81612c3`) surfaced a first-party, dated incident that is the strongest evidence for this entire document.

The legacy away-mode daemon (`cs-daemon.sh`, since deleted) read a soldier-authored `state/<id>.status` line and retyped its content, verbatim, into the orchestrator's own pane, wrapped in an "away-supervisor" envelope meant to look like a trusted system directive.
The wrapping used a marker byte sequence (`U+2063`) intended to help the boss visually distinguish supervisor text from soldier text.
That marker was never an authenticity control.
Any agent, including a compromised or prompt-injected soldier, could emit the same bytes, because the marker was chosen for human disambiguation, not for cryptographic verification.
This was tracked as SEC-01, closed only by deleting the daemon outright and retiring the entire distillation step onto plain watch/monitor/activate scripts that no longer retype soldier text as supervisor text.
A related finding, SEC-02, remains open in the legacy system: any prefix-matched marker sequence reaching the reading orchestrator's pane is still forgeable, and the legacy documentation itself notes that an LLM reader has no way to verify a cryptographic HMAC embedded in plain text it is asked to read.
The legacy fix for SEC-01 was structural (delete the channel), not cryptographic, precisely because the underlying problem is a channel-separation problem: text authored by a lower-trust principal must never be capable of being read, by any principal, as if it came from a higher-trust one.

Consigliere-next generalizes this lesson past status lines specifically to workspace marker files, Git configuration, and any other Agent-writable surface: nothing an Agent can write is ever treated as authoritative, no matter how it is formatted, named, or marked.
Authority comes only from database rows the Agent cannot write, and from SHAs the daemon itself has verified and imported.
This is why section 9.5 below states plainly that marker files are diagnostic only, and why the checkpoint sequence in section 9.3 below routes every state transition through a daemon-owned table, never through anything left behind in a workspace directory.

## Trusted Project mirror

Each Project has a daemon-owned bare repository:

```text
trusted/projects/<project-id>.git
```

Agents have no filesystem access to this repository and no credential that could reach it even if they discovered its path.
It stores trusted default-branch refs, imported checkpoint commits, validated delivery commits, delivery refs, and any control-plane-owned repository metadata.
It must never execute an Agent-controlled hook, and its own Git configuration is fully daemon-controlled (see "Privileged Git" below); nothing about how this repository behaves depends on anything an Agent wrote anywhere.

## Mission workspace

Each Mission receives an isolated, uncredentialed clone:

```text
workspaces/<mission-id>/
```

The clone is writable only by the worker boundary assigned to the current Attempt and by the daemon-controlled import process.
It carries no GitHub delivery credential, no Linear credential, no access to the trusted mirror, no access to any other Mission's workspace, and no privileged push remote.
It is disposable after its checkpoint has been imported and any artifacts worth preserving have been captured; nothing about Mission continuation depends on the workspace directory surviving.
V1 uses one isolated clone per Mission rather than a shared worktree or object store, even at higher disk cost, because correctness (no cross-contamination between Missions, no ambiguity about which clone is "the" workspace for a Mission) must be proven before that cost is optimized away.

## Committed-SHA checkpoints: the full sequence

An Attempt's checkpoint is durable only once it exists as a committed SHA that the daemon has imported into the trusted mirror.
Nothing before that point is durable Mission state; it may be preserved for diagnosis, but a crash before import can lose it without violating any invariant, because no invariant was ever staked on it.

The sequence below names the actor at each step (Agent, Runner, or Daemon) and the crash window that follows it, using the crash-window discipline from the master architecture's engineering-discipline section: what happens if the process dies before this step's effect is durable, and what happens if it dies after.

1. **Agent commits its current work**, including WIP when necessary, inside its Mission workspace clone.
   Crash window: if the Agent process dies before this commit exists, there is nothing to recover; the last imported checkpoint remains the Mission's durable state, and a fresh continuation starts from it. No data is lost that was ever promised to be durable.

2. **Agent reports the commit SHA** to the daemon using its Attempt capability (a scoped, short-lived credential; see `authority-model.md`).
   Crash window: if the Agent or its connection dies after committing but before this report is delivered, the commit exists only in the workspace clone, which is not yet daemon-visible as a checkpoint. The Reconciler will later find the workspace in an ambiguous state (see "Workspace reuse" below) and must not assume the uncommunicated commit is a valid checkpoint just because it exists on disk; only a reported and durably recorded checkpoint request counts.

3. **Daemon records a checkpoint request** as a durable row (through the single serialized write path in `Consigliere.DatabaseWriter`) before doing anything else with it.
   Crash window: this step is itself one short transaction; it either commits entirely or not at all, per the SQLite operational rules in `database.md`. There is no partial state possible here.

4. **Attempt exits.**
   Crash window: if the Attempt process or its harness does not exit cleanly, this is exactly the condition the Runner protocol (`protocols/runner.md`) exists to handle: the Runner terminates the process group directly rather than waiting indefinitely for a graceful exit.

5. **Runner verifies the process group is dead.**
   Crash window: this verification must be based on process-inventory evidence (an actual check that no process in the group remains), never on output silence alone, per invariant 12 in the master architecture. If verification cannot be conclusively completed (for example, because the daemon itself died mid-verification), the workspace must be treated as unverified, not as clean.

6. **Workspace becomes daemon-exclusive.**
   Once process-group death is confirmed, no Agent-controlled process has any further claim on the workspace directory; only the daemon's own import process touches it from this point forward.

7. **Daemon neutralizes Agent-controlled Git execution settings** in the workspace clone before running any Git command against it (see "Privileged Git" below for the specific neutralizations required).
   Crash window: if the daemon dies after step 6 but before this neutralization completes, the Reconciler must re-run neutralization from scratch on next boot before trusting anything in the workspace; a half-neutralized workspace is not safe to import from.

8. **Daemon verifies commit identity and ancestry**: that the reported SHA actually exists in the workspace clone's object store, and that its ancestry is consistent with the Mission's prior checkpoint (no unexpected history rewrite).
   Crash window: purely a read-only verification; safe to re-run idempotently after any crash.

9. **Daemon imports the commit into the trusted mirror** using a privileged Git operation that pulls only the specific verified SHA from the neutralized workspace clone into `trusted/projects/<project-id>.git`.
   Crash window: this is the step where "before external success" versus "after external success" matters most. If the daemon dies mid-import, the trusted mirror may or may not already contain the object; the import operation must be re-run in a way that is safe to repeat (importing an object that is already present is a no-op, not an error), so retrying after a crash here is always correct.

10. **Imported SHA becomes the authoritative checkpoint**, recorded as the Mission's `current_checkpoint_sha` in one short transaction.
    Crash window: if the daemon dies after step 9 but before this transaction commits, the object exists in the trusted mirror but the Mission row does not yet point at it; on restart, the Reconciler must detect this exact gap (object present in the mirror, not yet reflected as the Mission's current checkpoint) and complete the transition rather than silently leaving the Mission pointed at a stale checkpoint or re-importing from scratch.

11. **A continuation may begin**, using the newly authoritative checkpoint as its base.
    Nothing before step 10 is a valid base for a continuation; a continuation must never be started from an Agent-reported SHA that has not yet cleared steps 7 through 10.

Uncommitted files in a workspace may be preserved for incident diagnosis (for example, copied aside before a workspace is quarantined or discarded), but they are never durable checkpoint state under any circumstance; this is stated as its own invariant in the master architecture precisely because it is tempting, during an incident, to treat "the files are still sitting right there" as good enough. They are not, because nothing has verified them, imported them, or fenced out a stale process that might still be writing to them.

## Workspace reuse

A workspace may be reused only after the previous process group's death is conclusively verified, per step 5 above.
If death cannot be proven, for any reason, including the daemon itself having been unavailable at the moment verification was needed, the workspace must be quarantined rather than reused: it is not deleted, it is not overwritten, and a fresh clone is made from the last imported checkpoint for any continuation, using a new continuation branch or ref where needed.
Quarantining a workspace this way always creates an incident, so that a human eventually looks at why verification failed and whether the quarantined directory contains anything worth manually recovering.
This rule directly targets the anti-pattern found in the Symphony reference codebase during Phase 0 grounding: Symphony's `Workspace.create_for_issue/2` (`workspace.ex:15-38`) keys a workspace purely by issue id, reusing or recreating it in place (`ensure_workspace/2`, lines 40-91) with no commit-SHA checkpoint and no verification that a prior process touching that path is actually gone. A path-keyed, liveness-unverified reuse model is exactly what allows a stale or still-running process to corrupt a workspace that a new Attempt believes it owns exclusively; consigliere-next's SHA-anchored, verify-before-reuse model exists specifically to prevent that failure mode.

## Marker files

Any marker file left in a workspace, whether written by an Agent or by tooling running inside the Agent's process boundary, is a diagnostic hint only.
It may help a human or the Reconciler understand what happened, but it confers no authority and proves nothing on its own.
Identity and authority derive exclusively from database rows, canonical paths recorded by the daemon, trusted imported SHAs, and active fencing tokens.
An Agent-writable marker is never trusted as authority, under any circumstance, including a marker that looks like it was written by the daemon; the daemon does not write markers into Agent-writable workspace locations for this exact reason, since a marker's trustworthiness cannot be distinguished from a forged one once it sits inside an Agent-controlled directory.
This generalizes the SEC-01/SEC-02 lesson directly: the legacy incident's forgeable "supervisor" marker in a status line is structurally the same risk as a forgeable "clean" or "owned-by" marker in a workspace directory, and the fix is the same, the marker is never the source of truth, only a hint for a human or a diagnostic tool that already knows to distrust it.

## Privileged Git

Every control-plane Git command, whether importing a checkpoint into the trusted mirror or pushing from the trusted mirror to a remote, must neutralize any Agent-controlled Git execution configuration before it runs. At minimum, this means:

- neutralizing Git hooks (running with hooks disabled or pointed at an empty, daemon-controlled hooks path, never the workspace's own `.git/hooks`),
- neutralizing `fsmonitor` and any other configurable hook-adjacent integration point,
- scrubbing the Git environment of any variable the workspace clone or its configuration might have set,
- never inheriting a credential helper defined by the workspace clone,
- never using a remote defined by the workspace clone for a privileged push; the remote URL for privileged push comes only from the Project row, stored and controlled by the daemon,
- never interpolating tracker text or Agent-authored prose into a shell command; any value that reaches a Git invocation from Agent-controlled input (a commit message, a branch name proposed by an Agent) must be passed as a discrete argument, never built into a command string.

Privileged push happens only from the trusted mirror, using the explicit URL stored in the Project row, a daemon-owned credential channel, an explicit source SHA, and an explicit destination ref; see `protocols/made-managed-mode.md` and the delivery/integration architecture for how this composes with validation and merge authorization.

## Open questions flagged during drafting

- The exact mechanism for "neutralizing the Git environment" (an explicit allowlist of environment variables passed through, versus a fully scrubbed environment with only what the daemon needs re-added) is not chosen yet; this document assumes a scrubbed-and-rebuilt environment, since an allowlist risks missing a future Git environment variable that has security relevance.
- Whether quarantined workspaces are ever automatically garbage-collected after some retention period, or whether they require explicit human disposal every time, is left open; automatic collection risks discarding forensic evidence relevant to an open incident, but no retention keeps disk usage strictly growing.
- This document assumes one clone per Mission for the entire Mission lifetime, including across repair Attempts within the same Mission; whether a repair Attempt gets a fresh clone from the newly imported checkpoint or reuses (post-verification) the same clone is not fully resolved, and should be settled during Phase 2's workspace-reuse spike.
