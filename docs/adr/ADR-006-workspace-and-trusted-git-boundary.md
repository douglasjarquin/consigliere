# ADR-006: Workspace and trusted-Git boundary

## Status

Proposed.

## Context

Two independent negative precedents were found for treating a filesystem path, rather than a database row anchored to a committed SHA, as the authority for "which work this workspace represents" and "who is allowed to push from it."

Symphony's `Workspace.create_for_issue/2` (`workspace.ex:15-38`) creates a plain local directory (`File.mkdir_p!`) or a remote directory over SSH, keyed purely by issue id; `ensure_workspace/2` (lines 40-91) reuses or removes it by that same path-derived key.
There is no commit-SHA-based checkpointing anywhere in this flow: workspace identity is a path keyed by an external tracker's issue id, which is precisely the "marker file / path as authority" pattern master-prompt section 9.5 warns against, just instantiated as a directory name instead of a marker file's contents.

Legacy Consigliere's `docs/operational-input-provenance.md` documents a related but distinct failure in the same family: a Unicode marker (`U+2063`) was used to mark an envelope of text as "trusted," but the marker itself carried no authenticity guarantee, since any agent producing that byte sequence could cause its own text to be read as authoritative (SEC-01, closed by deleting the responsible daemon; SEC-02, still open).
The common thread across both precedents is the same: a piece of state an Agent-controlled process can produce or influence (a path name, a marker byte sequence) was being treated as if it conferred authority, when it conferred nothing except a hint.

## Decision

Workspace and Git trust follow master-prompt section 9 exactly:

- Each Project has a daemon-owned bare repository (`trusted/projects/<project-id>.git`) that Agent-controlled processes cannot access, storing trusted default-branch refs, imported checkpoint commits, validated delivery commits, and delivery refs. It never executes Agent-controlled hooks or configuration.
- Each Mission gets an isolated, uncredentialed clone (`workspaces/<mission-id>/`), writable only by the assigned worker boundary and the daemon-controlled import process, with no delivery credentials, no access to the trusted mirror, and no access to other workspaces. V1 uses isolated clones even at extra disk cost; shared worktrees or object stores are not attempted before correctness is proven.
- A checkpoint is durable only once it is a committed SHA that has been imported into the trusted mirror: Agent commits, reports the SHA via its Attempt capability, the daemon records a checkpoint request, the Attempt exits, the runner verifies the process group is dead, the workspace becomes daemon-exclusive, the daemon neutralizes Agent-controlled Git execution settings, verifies commit identity and ancestry, and only then imports the commit as the authoritative checkpoint. Uncommitted files may be preserved for diagnosis but are never durable checkpoint state.
- Workspace reuse is allowed only after previous process-group death is conclusively verified; if death cannot be proven, the workspace is quarantined, not reused, and an incident is created.
- Marker files remain diagnostic hints only; identity and authority derive exclusively from database rows, canonical paths, trusted imported SHAs, and active fencing tokens.
- Privileged Git commands (import, push) neutralize hooks, fsmonitor, and Git environment variables, never inherit workspace credential helpers or workspace-defined remotes, and never interpolate tracker or Agent prose into a shell command. Privileged push runs only from the trusted mirror, using the Project row's explicit URL, a daemon-owned credential channel, an explicit source SHA, and an explicit destination ref.

## Consequences

- Symphony's path-keyed-by-issue-id failure mode becomes impossible by construction: workspace identity is a database row (with a lease id and fencing token), and the only thing that can ever become an authoritative checkpoint is an explicitly imported, ancestry-verified commit SHA, not "whatever happens to be in this directory."
- SEC-02's specific attack (Agent-controlled text laundered as trusted directive) cannot recur in the Git boundary specifically, because no Agent-writable file, marker, or environment variable is ever trusted for a privileged Git operation; the neutralization list (hooks, fsmonitor, env vars, credential helpers, remotes) exists precisely to close off every channel through which an Agent could otherwise smuggle influence into a privileged command.
- Isolated per-Mission clones cost real disk space compared to shared worktrees or a shared object store; this is accepted deliberately for V1, since correctness (no cross-Mission workspace bleed) is prioritized over disk efficiency until the isolated-clone model is proven and a shared-storage optimization can be justified by evidence rather than assumed safe.
- The checkpoint-import sequence is more steps than "just commit and move on," including an explicit process-group-death verification step before the workspace becomes daemon-exclusive; this is deliberate, since skipping it is exactly how a "dirty workspace was deleted" or "stale process mutated a reused workspace" incident would occur.

## Alternatives considered

**Path- or marker-keyed workspace identity** (Symphony's actual model). Rejected directly: it provides no defense against a stale or duplicated directory being mistaken for the authoritative one, and no SHA-level guarantee that what is in the directory is what was actually validated.

**Trusting Agent-controlled Git configuration in privileged operations** (i.e., running import/push using whatever hooks, remotes, or credential helpers happen to exist in the Mission workspace). Rejected on SEC-01/SEC-02 grounds directly: any configuration an Agent-controlled process can write is a channel that process can use to influence a privileged operation, which is the same shape of vulnerability as the marker-laundering incident, just expressed through Git configuration instead of pane text.

**Shared worktrees or a shared Git object store across Missions**, to reduce disk usage. Deferred, not rejected outright: master-prompt section 9.2 explicitly defers this until correctness is proven with isolated clones first; introducing shared storage before that risks reintroducing cross-Mission bleed for a disk-space optimization that has not yet been shown necessary.

## Revisit trigger

Reopen this ADR if Phase 2's required tests (Agent sets malicious hooks/fsmonitor/credential helper/origin and privileged Git paths must ignore all of it; a process that cannot be conclusively killed must quarantine its workspace rather than being reused) fail to hold, or if isolated-clone disk consumption becomes an operationally proven bottleneck after real pilot usage, at which point a shared-storage design should be evaluated against the correctness properties proven here, not before.
