# Architecture

How consigliere works, in depth.
The always-loaded operating contract is [`AGENTS.md`](../AGENTS.md); this is the human-facing companion.
Consigliere is a personal rewrite of Firstmate for two harnesses (codex and claude) and one terminal runtime (herdr); soldiers inherit the root session's harness. [`docs/upstream.md`](upstream.md) owns the relationship to upstream.

## Two harnesses, one runtime

`bin/cs-harness-lib.sh` is a thin harness-profile layer - the single owner of every per-harness fact (launch template, turn-end wiring, busy signature, skill syntax, resume command, instruction file). It is the only harness abstraction; the optional per-home dispatch policy is documented in [`docs/configuration.md`](configuration.md) and applied by `bin/cs-spawn.sh`. A soldier inherits the root session's harness (`cs_harness_detect_root`) and records it as `harness=` in `state/<id>.meta`.
`bin/cs-herdr-lib.sh` is the whole herdr layer (session-explicit CLI, workspace/worktree/pane/agent operations, the busy-corroboration policy); [`docs/herdr.md`](herdr.md) is its evidence ledger.
Per-harness verified facts live in [`docs/codex.md`](codex.md) and [`docs/claude.md`](claude.md); the launch strings exist once, in `bin/cs-harness-lib.sh` (assembled by `bin/cs-spawn.sh`).

## Typed operational input

`bin/cs-operational-input.sh` is the single construction and classification owner for machine-generated session input.
Its current wire form is `U+2063 CONSIGLIERE_OP: v1 <kind>: <body>`, with kinds `launch-brief`, `session-start`, `watcher`, `turn-end-guard`, and `away-supervisor`.
The compatibility kind `from-consigliere` retains the byte-identical `[cs-from-consigliere]` label followed immediately by U+2063, while the away form retains bare leading U+2063 before its typed header.
Unmarked input classifies as `boss`; provenance never depends on body prose.
The U+2063 marker is a **boss-disambiguation aid, not an authenticity control**: it is unforgeable by boss keystrokes (U+2063 has no key), but an agent can emit those bytes verbatim, so a present marker is not proof of consigliere provenance. Where agent-authored text is folded into a trusted envelope — the away-mode daemon distilling soldier status lines into an `away-supervisor` digest — that text is neutralized as quoted DATA first (`cs_operational_input_neutralize`) so a soldier cannot launder a forged marker into trusted framing (docs/operational-input-provenance.md, option C). Full cryptographic integrity on the machine-classified channel (HMAC) is a documented, deferred follow-up.
`bin/cs-marker-lib.sh` is a thin compatibility entry point for legacy marker callers.

## Workspace-per-task, herdr-native worktrees

`herdr worktree create --cwd <project> --branch cs/<id> --label <id>` creates the isolated task worktree at `~/.herdr/worktrees/<repo>/<branch>` AND its own workspace whose root pane is the task pane.
There is no worktree pool: create is fast, dirty removal fails closed upstream, a clean removal preserves the branch, and a surviving worktree is recovered with `herdr worktree open --path` after a workspace or server loss.
`bin/cs-spawn.sh` refuses to launch unless the physically-resolved worktree root is a real git toplevel distinct from the project primary checkout.
Capo homes are the exception: a capo home must survive server restarts and empty workspaces, so it is a plain detached `git worktree` of the consigliere repo under `~/.consigliere/capos/<id>`, marked by `.cs-capo-home`, never herdr-managed.

## Event-driven supervision

A zero-token bash watcher (`bin/cs-watch.sh`) sleeps on the fleet, classifies wakes in bash, and wakes consigliere only when something is actionable; actionable wakes are written to the durable `state/.wake-queue` before detector state advances.
The absorb policy is absorb-only-when-provably-working: a no-verb signal or fresh stale pane is absorbed only with positive working evidence (an attributed no-mistakes run step from `bin/cs-crew-state.sh`, or native-busy corroborated per docs/herdr.md), a declared `paused:` idles on a long bounded cadence, and a provably-working stale escalates past the wedge threshold with a `demand-deep-inspection` marker on repetition.
Native herdr `blocked` surfaces immediately - sub-second via the socket event splice (`bin/cs-herdr-events.py`, `pane.agent_status_changed`) and on the next poll without it; the poll loop is the permanent fail-closed backstop.
`bin/cs-classify-lib.sh` is the one owner of the status-verb vocabulary and the keyed decision/activity folds, shared by the watcher and the away-mode daemon, and consumes operational-input types from `bin/cs-operational-input.sh`.
Who writes a decision's closing line lives with each writer: consigliere closes at answer time through `bin/cs-send.sh`'s `--resolve-key`, `bin/cs-pending-reply-lib.sh` closes its own capo escalations when the request resolves, and a soldier self-closes only a blocker that cleared without an answer.
The supervision wait shape is the bounded foreground checkpoint ([`docs/supervision.md`](supervision.md)); the harness Stop hook (`bin/cs-turnend-guard.sh`, registered per-harness) is the structural backstop.

## Authenticated checks

The watcher executes a task's `state/<id>.check.sh` only from a hash-validated private snapshot bound by `bin/cs-check-register.sh`; everything else is rejected without execution.
The PR merge poll is byte-static: `bin/cs-pr-check.sh` records a canonical PR identity and any available head, then publishes a validated data sidecar that `bin/cs-pr-poll.sh` (a trusted repository script) revalidates on every dispatch.
For an eligible release, that hash-bound sidecar also carries the exact-head board-capacity attestation consumed by `bin/cs-board-capacity.sh`; it never changes merge-poll semantics.
After a merged result is durably queued, the watcher retires that poll's runnable check and sidecars, while task metadata remains for teardown and a re-armed different PR stays protected by identity revalidation.
GitHub only; GitLab URLs are refused loudly at arm time.

## Two task shapes, three delivery modes

Ship tasks change projects and land by the mode decided per task at intake and passed explicitly to `bin/cs-brief.sh`, `bin/cs-spawn.sh`, and `bin/cs-promote.sh`: `no-mistakes` (the external pipeline owns review through PR; consigliere feeds gate decisions, never drives a soldier-owned run), `direct-PR`, or `local-only` (guarded fast-forward via `bin/cs-merge-local.sh`).
`bin/cs-delivery-lib.sh` owns that vocabulary and the one machine-readable line (`Delivery contract: mode=<mode>`) the brief carries so `bin/cs-spawn.sh` can refuse a spawn whose `--mode` disagrees with it - before the worktree exists - instead of letting the worker's definition of done and the task's durable record diverge.
`config/projects.md` (`bin/cs-project-mode.sh`) records only the boss's advisory standing posture per project: a task shipping with less rigor gets a deviation notice and continues, and an unregistered project has no standing posture at all.
Scout tasks leave a report at `data/<id>/report.md`, never push, and their scratch worktree is discarded only after the report exists and `bin/cs-decision-hold.sh verify` passes; a scout records no delivery posture at all, so `bin/cs-promote.sh` - which flips a scout to ship in place - is where a promoted task first states one.
`bin/cs-teardown.sh` owns the fail-closed landed-work proofs (uncommitted never landed; landed = remote-reachable OR merged-PR-head containment OR content already in the up-to-date default branch), with the git-lock staleness proof from `bin/cs-lock-lib.sh`.

## Capos

A capo is a soldier with an isolated consigliere home (`CS_HOME`) and a charter, not a second architecture: own data/state/config/projects, own session lock, own watcher, workspace `capo-<id>`.
`bin/cs-home-seed.sh` provisions transactionally and sweeps (fast-forward plus liveness respawn for recorded endpoints, reporting missing endpoints and staying silent for seeded homes without metadata) at bootstrap; `host/capos.md` is the routing table; marked requests travel with the byte-compatible `from-consigliere` kind and a `corr=` token, with parent-owned expectations in `bin/cs-pending-reply-lib.sh`.
Inheritance is deliberately tiny: `config/boss-shared.md` (read-only) and the backlog-backend choice (`bin/cs-inherit-lib.sh`).

## Away mode

`/afk` sets the durable `state/.afk` flag and starts `bin/cs-daemon.sh`, a presence-gated sub-supervisor that self-handles routine wakes in bash and injects batched `away-supervisor` digests into the primary's own pane (recorded at afk-start from `HERDR_PANE_ID`), only into an affirmatively empty composer (`bin/cs-composer-lib.sh` strips codex ghost text before judging emptiness).
Input classified `boss` means the boss returned; `bin/cs-afk-return.sh` owns ordered shutdown and the fail-closed catch-up gate.

## Restart-proof

Durable state and live herdr inventory, not conversation memory, are authoritative: `bin/cs-session-start.sh` reproduces the whole operating picture in one digest, and a restart is a non-event.
The harness session-open hook runs that digest itself (`bin/cs-sessionstart-run.sh` owns what each open source means), so starting up is not the agent's discretion, and the digest is bounded as one child that reports a stalled stage loudly instead of silently.
Because that hook blocks session initialization, the digest is composed from local reads alone: the external-network checks (the `gh auth` probe and the fleet-sync fetch) run concurrently in a bounded detached worker (`bin/cs-startup-network.sh`) whose result is harvested inline when it finishes in time and arrives as a `check: startup-network` wake when it does not, so a slow network delays a reported check rather than the work queue.
Self-updates are fast-forward-only git pulls of this repo (`bin/cs-update.sh`), which never touch the gitignored operational home or anything under `projects/`; `bin/cs-fleet-sync.sh` separately keeps project clones fresh.

## Development notes

Tests are colocated in `tests/` (offline by default; live suites behind `CS_TEST_HERDR_LIVE`/`CS_TEST_CODEX_LIVE` use `bin/cs-herdr-lab.sh` isolated sessions, never the `default` session).
Every bin script is ShellCheck-clean under the canonical lint `bin/cs-lint.sh`, which owns the file set, flags, and pinned version; one sentence per line in contract prose; scripts own their exact mechanics in their headers.
