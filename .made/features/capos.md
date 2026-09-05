# Capos

## Sub-features

- A capo is a persistent Consigliere home with its own configuration, backlog, state, and project registry.
- Capo routing keeps delegated ownership separate from the main home and survives server restarts.
- Capo-spawned soldiers can nest in the capo workspace when the recorded target is live.
- Seed and sweep operations converge a capo home without touching project clones outside their scope.

## How to get to it (user POV)

Ask Consigliere to create or recover a capo for a durable area of responsibility, then route work to that named home.

The capo behaves like an independent Consigliere home while the main session remains the boss's single point of contact.

## Driving it

- `bin/cs-home-seed.sh` owns capo creation, seeding, validation, sweep, and recovery mechanics.
- `bin/cs-capo-registry-lib.sh` owns the machine-local `host/capos.md` routing schema.
- `skills/capo-provisioning/SKILL.md` owns the authority and rollback procedure for capo homes.
- `docs/configuration.md` owns the home layout and symlink policy.

## Gotchas

- Capos are idle by default, and an empty queue does not authorize a self-directed survey.
- Capo state is home-local and must not be inferred from the main home's project list or status files.
- A failed seed or recovery leaves generated briefs, homes, clones, and registry records subject to the documented rollback path.
