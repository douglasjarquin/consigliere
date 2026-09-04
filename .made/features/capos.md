# Capos

A capo is a persistent helper with its own isolated consigliere home and a charter, not a second architecture.

## Sub-features

- charter then seed: scaffold a charter brief, then provision a detached-worktree home and registry row in one transactional seed.
- routing: send in-scope work to the fitting capo by the nature of the work against `scope:`, not by a non-exclusive clone list.
- idle by default: an empty queue is healthy and never authorizes a self-directed survey.
- recovery and retirement: recover a dead capo in its own home; retire only on an explicit decision after the home has no work under way.

## How to get to it (user POV)

The boss asks for a standing helper for a domain.
That helper lives in its own home, keeps its own queue, and takes work that matches its charter.
The boss still talks only to the main consigliere; the capo's replies come back as outcomes or a document pointer.

## Driving it

- `skills/capo-provisioning/SKILL.md` owns create, seed, validate, launch, handoff, recover, retire, and `host/capos.md` edits.
- `bin/cs-brief.sh <id> --capo` scaffolds the charter; `bin/cs-home-seed.sh` provisions the home; `bin/cs-spawn.sh <id> <home> --capo` launches it.
- `bin/cs-capo-registry-lib.sh` is the single reader of `host/capos.md`.

## Gotchas

- Capos never appear in the main home's backlog; their routed work lives in their own home.
- `local-only` projects stay with the main consigliere.
- A project a capo's `projects:` list names refuses to spawn from any other home unless the boss explicitly redirects with `--here`.
- Do not read the capo's chat; marked routed replies return through status or a referenced document.
