# Session start and lock

How a consigliere session becomes the fleet owner, or stays read-only when another session already holds that lock.

## Sub-features

- session-start digest: one ordered dump of lock, bootstrap, fleet, network, and context so the session does not re-read those sources.
- per-home lock: only the session that holds it may spawn, steer, merge, drain, or otherwise mutate fleet state.
- read-only start: a refused lock still prints a detect-only digest and forbids mutation.
- deferred network: GitHub auth and clone refresh run off the lock-holding path and are harvested without blocking the digest.

## How to get to it (user POV)

The boss opens a consigliere session in this repo.
A run-tier harness runs session start for them; otherwise the agent runs it exactly once and trusts the digest.
If another live session already holds the lock, this session reports that it is read-only and does not take new fleet work.

## Driving it

- `bin/cs-session-start.sh` is the single entry; its header owns digest stages and the read-once contract.
- `bin/cs-lock.sh` acquires the per-home lock.
- `AGENTS.md` section 3 is the always-loaded trigger; `docs/configuration.md` owns the files the digest prints.

## Gotchas

- Do not re-run session start when the digest is already present.
- Do not bulk-read `config/backlog.md` or `state/*.status` after the digest; go to a source only when the digest flagged it missing, corrupt, or truncated.
- A `state/<id>.status` line is a notification, not current-state truth; `bin/cs-crew-state.sh` reconciles current state.
- A lock refusal is a stop on fleet mutation, not a prompt to work around the lock.
