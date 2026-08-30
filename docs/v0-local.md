# Consigliere Local V0

This document is the authoritative product contract for the local V0 revival.

## Purpose

V0 answers whether deterministic local software can preserve the useful coordination of FirstMate with materially less orchestration overhead.

V0 is a local, single-home, single-worker path owned by the Elixir daemon and operated through the packaged Go clients.

SQLite is authoritative for durable Projects, Missions, Attempts, capabilities, authorizations, operations, checkpoints, events, verification, and recovery state.

Git, filesystem, process, network, and Codex work is external to SQLite transactions and is represented by durable intent followed by reconciliation.

The daemon binds every external action to the authenticated authority, exact Project and Mission identities, workspace lease and generation, fencing generation, and exact Git SHAs.

The boss remains the only authority that authorizes work, answers boss-scoped Questions, waives policy, authorizes delivery, pushes, creates pull requests, or merges.

The model-advisory channel can read bounded state and draft safe actions, but it cannot exercise boss or delivery authority.

## Included contract

The packaged release provides `csd migrate`, `csd start`, `cs ping`, `cs doctor`, `cs status`, `cs why`, `csd stop`, and `csd restart`.

The terminal golden path registers one trusted local Project, creates and submits one Mission, requests explicit work authorization, dispatches exactly one recoverable Attempt, runs one fresh Codex session, imports one verified result by exact SHA, runs bounded local verification, and stops at `ready_for_review`.

Project registration canonicalizes the repository identity, resolves the configured default branch, imports its tip into a daemon-owned bare mirror, and records the immutable base SHA.

Worker workspaces are independent materializations with no alternates, inherited hooks, privileged remotes, credential helpers, symlink substitutions, or unsafe permissions.

Mission authorization displays the exact Project, Mission, objective, scope, acceptance criteria, and base SHA before a foreground boss confirmation.

Authorization, dispatch, runner launch, control-channel authentication, Codex execution, termination, exact-SHA import, verification, and review-ready projection are each durable and idempotent.

The public V0 API returns bounded typed envelopes and never stores credentials, full prompts, full transcripts, or unbounded command output.

The per-turn ledger stores only bounded identity fields and counters exposed by the configured Codex CLI.

## Exact golden path

The following commands describe the operator path from a fresh packaged installation.

```text
scripts/package.sh PREFIX
export PATH=PREFIX/bin:$PATH
export CS_RELEASE=PREFIX/libexec/consigliere_daemon
export CS_HOME=HOME/.consigliere
csd migrate
csd start
cs project add --name NAME --path PATH --url URL --default-branch BRANCH
cs mission create --project PROJECT --objective OBJECTIVE --scope SCOPE --acceptance ACCEPTANCE
cs mission submit MISSION
cs mission authorize MISSION
cs status MISSION
cs why MISSION
cs review MISSION
csd stop
csd restart
```

The client uses the daemon socket and never opens the SQLite database or mutates the trusted mirror.

Human output is stable and readable, while `--json` returns the versioned envelope without changing authority or side effects.

Automation supplies the exact Mission identity and a stable logical idempotency key.

The boss confirmation is foreground and explicit, and a lost response is retried with the same logical key.

The path creates no pull request, performs no push, and performs no merge.

An Attempt reports a full exact result identity and terminal event sequence through its authenticated capability channel.

The daemon waits for verified runner death, verifies the result in the bound Workspace, imports it once to the daemon-owned Project result ref, and records the same SHA on the Attempt and Mission.

Only bounded local Project verification can advance the Mission to `ready_for_review`.

The boss can continue a checkpoint by naming its exact current SHA, which creates a fresh Attempt and Workspace generation without native Codex transcript resume.

## Ordered implementation queue

The implementation queue is fixed for this revival and is executed in this order.

1. #139 establishes the V0 baseline, scope, and green CI.
2. #124 enforces one kernel-owned daemon per `CS_HOME`.
3. #125 makes commands idempotent and keeps external work outside transactions.
4. #127 binds Projects and workspaces to immutable trusted Git identities.
5. #131 completes terminal Project, Mission, and authorization workflow.
6. #132 enforces minimal per-Attempt capabilities.
7. #137 authenticates private runner control channels.
8. #121 dispatches exactly one recoverable Attempt after authorization.
9. #122 executes real Codex work with bounded context and no native resume.
10. #135 bounds and acknowledges API, event, log, and usage data.
11. #126 reconciles runner identity, liveness, termination, and outcomes.
12. #134 makes `csd stop` and restart identity-safe.
13. #123 imports successful work by exact SHA and marks it review-ready.
14. #136 adds the thin non-authoritative model-advisory interface.
15. #140 runs the operator-controlled comparison against optimized FirstMate.

No later queue item authorizes bypassing an earlier item.

## Trusted-local threat model

The daemon treats the local filesystem, local processes, runner input, Codex output, repository content, and model-generated text as untrusted at their boundaries.

The boss credential is restricted to the explicit human channel and is never copied into a worker environment, advisory process, context pack, log, event, or durable record.

Attempt capabilities are short-lived, revocable, exact-Attempt credentials with an explicit closed operation allowlist and exact Mission, workspace, lease, and fence scope.

The Home.Lock is the kernel-managed authority for a canonical `CS_HOME`, and owner metadata and socket presence are diagnostic evidence rather than ownership authority.

Runner control authentication binds the invocation, Attempt, Mission, workspace, generation, fence, protocol, runner process identity, manifest digest, and executable hash.

Git trust is anchored in the daemon-owned mirror and exact refs, not source-checkout `HEAD`, timestamps, object discovery, caller paths, or GitHub delivery state.

External work is never treated as complete from an event, an exit code, a PID absence, or model prose alone.

All protocol, collection, string, log, event, text, and usage inputs are bounded before allocation or durable append.

Prompt injection, malicious tool output, forged manifests, stale state, dirty workspaces, path traversal, unsafe control sequences, and credential-shaped values must fail closed or be redacted without widening authority.

## Bounded measurement schema

Each local measurement record is keyed by system, Project, Mission, Attempt, session, model, reasoning effort, CLI version, context hash, and recorded timestamp.

The record may contain coordinator input tokens, coordinator output tokens, cached input tokens, worker input tokens, worker output tokens, elapsed time to review-ready, compactions or resets, human interventions, status checks, retries or rework, stale or duplicate work, and daemon or harness incidents.

The record stores bounded counters and typed outcomes only, with no full prompt, transcript, raw credential, raw secret-bearing event, or unbounded tool output.

The public report contains per-Mission and aggregate measurements, definitions, exclusions, limitations, incidents, workarounds, operator burden, and the explicit human decision.

Raw ledgers remain private to the selected canary `CS_HOME`.

The canary does not prescribe a Project, task sample, duration, Continue limit, allocation, or duplicate paired work.

At least 20 naturally occurring comparable Mission records across both systems are required before a Promote decision.

Promote also requires defensible measurements, no lost durable work, no duplicate workers or authorizations, convergent interruption recovery, no material increase in human intervention or status checks, no material CI or review rework regression, no higher median cognitive burden, and at least 40 percent lower orchestration quota or token use per review-ready change.

Fewer than 20 comparable records or any indefensible metric produces an explicit insufficient-evidence result and cannot produce an economic-superiority claim.

## Evidence and scope rule

Every queue item has automated tests, a real packaged, process, or terminal scenario, an evidence record under `.omo/evidence/consigliere-local-v0-revival/task-N.md`, and cleanup receipts for resources it created.

The final verification records are `.omo/evidence/consigliere-local-v0-revival/F1.md` through `F4.md`.

Scope expands only after the canary evidence is complete, defensible, and reviewed by the boss.

The canary decision is exactly one human-authored `Promote`, `Continue`, or `Stop` decision.

An absent boss-selected Project, task sample, duration, FirstMate configuration, Consigliere configuration, or evidence sufficiency decision is a decision hold, not permission to guess.

## Exclusions

V0 does not include Capos, Secondmates, persistent per-repository managers, remote workers, multi-host coordination, a full-screen TUI, another production harness, or native Codex transcript resume.

V0 does not include Made-managed validation, AFK notifications, visible notification delivery, automatic GitHub delivery, product-created pull requests, pushes, or merges.

V0 does not include a telemetry platform, a broad evidence warehouse, full transcript retention, raw public canary data, or an automatic Promote path.

V0 does not depend on the legacy Bash supervisor or interactive shell version management.

Packaging scripts may retain their existing interpreter when the installed product runtime remains independent of that supervisor.

The current main-branch Bash fleet is outside this V0 change and is not ported to zsh.
