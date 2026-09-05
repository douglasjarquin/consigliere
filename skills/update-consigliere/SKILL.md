---
name: update-consigliere
description: Self-update a running consigliere and its capos to the latest from origin. Use when the boss invokes /update-consigliere or asks to update consigliere or pull the latest. Fast-forwards this repo's default branch and every capo home (fast-forward only, never forced, never disruptive), then re-reads AGENTS.md and nudges each updated capo to do the same.
---

# Update consigliere

1. Run `bin/cs-update.sh` and read its summary lines.
   It fast-forwards this repo's default branch from origin and sweeps every registered capo home; it never forces, merges, or stashes, and a tracked-files fast-forward never touches `data/`, `state/`, `config/`, `projects/`, `.made/evidence/`, or legacy `.no-mistakes/`, so in-flight work survives.
2. A `skipped` line is a report, not an error to fight: a dirty tree, diverged branch, or tangle is resolved by its own owner (commit/land the work, or follow the tangle guidance) - never by forcing the update.
3. If it prints `reread-consigliere: yes`, re-read `AGENTS.md` now and continue under the refreshed contract.
4. For each id in `nudge-capos:`, steer that capo to update itself:
   `CS_HOME=<main-home> bin/cs-send.sh <id> 'Your home was fast-forwarded; re-read AGENTS.md and continue under the refreshed instructions.'`
5. Nothing under `projects/` is ever touched by this flow; project clones are refreshed separately by the guarded fleet sync.
6. When the fast-forward changed `.codex/hooks.json`, tell the boss that each codex home's next interactive session must approve the changed hooks once before they fire again (persisted hook trust; see `docs/codex.md`).
