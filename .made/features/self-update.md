# Self-update

How a running consigliere and its capos take the latest origin without disrupting in-flight work.

## Sub-features

- fast-forward only: this repo's default branch and every registered capo home advance only when the update is a clean fast-forward.
- instruction refresh: if `AGENTS.md`, `bin/`, or `skills/` changed, re-read the kernel and nudge updated live capos to do the same.
- skip is a report: a dirty tree, diverged branch, or missing origin is named and left for its owner, never forced.

## How to get to it (user POV)

The boss says `/update-consigliere` or asks to pull the latest.
Consigliere fast-forwards itself and the capo homes, then continues under the refreshed instructions when those changed.
Project clones are not part of this flow.

## Driving it

- `skills/update-consigliere/SKILL.md` owns the boss-facing steps.
- `bin/cs-update.sh` owns the git mechanics and the parseable summary (`reread-consigliere`, `nudge-capos`).
- Capo-home fast-forward is the same implementation as `bin/cs-home-seed.sh --sweep`.

## Gotchas

- Never force, merge, or stash to make an update go through.
- A tracked-files fast-forward never touches gitignored operational dirs (`data/`, `state/`, `config/`, `projects/`, leftover `.no-mistakes/`); Made evidence lives on its own orphan branch, untouched by this fast-forward entirely.
- Nothing under `projects/` is refreshed here; fleet sync owns clone refresh.
- If `.codex/hooks.json` changed, each codex home's next interactive session must approve the changed hooks once.
