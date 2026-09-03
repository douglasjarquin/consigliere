# Self-update

## Sub-features

- The main home fast-forwards its default branch only when the checkout is clean and can advance safely.
- Registered capo homes receive the same guarded fast-forward sweep.
- In-flight operational state and project clones remain outside the tracked-files update.
- Instruction changes trigger a re-read and live capo nudges through the normal steer path.

## How to get to it (user POV)

Ask Consigliere to update itself when a newer default-branch revision is available.

It reports updated, already-current, or skipped homes and leaves conflicts for their owners instead of forcing them away.

## Driving it

- `bin/cs-update.sh` owns the fast-forward mechanics and parseable summary.
- `skills/update-consigliere/SKILL.md` owns re-read and capo-nudge follow-through.
- `docs/configuration.md` owns the boundary between tracked instructions, operational homes, and project clones.

## Gotchas

- The update path never forces, merges, stashes, or mutates anything under `projects/`.
- A dirty, diverged, or non-default checkout is a reported skip, not a reason to reset it.
- The shared Made daemon is not restarted by self-update.
