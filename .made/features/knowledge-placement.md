# Knowledge placement

## Sub-features

- `AGENTS.md` holds facts needed on every session or turn.
- `skills/` holds conditional procedures for a nameable situation, with a load trigger in the operating contract.
- `docs/` holds human reference detail, contracts, verified facts, and incident evidence.
- A script's header and `--help` output hold exact flags, commands, paths, and mutation mechanics.
- One-owner contracts are stated in full once, with other locations carrying only short cross-references.

## How to get to it (user POV)

When adding Consigliere knowledge, place it where the next reader will naturally look and keep the always-loaded contract small.

Before changing documentation, read the repository's `skills/consigliere-coding-guidelines/SKILL.md` and apply its decision tree.

## Driving it

- `skills/consigliere-coding-guidelines/SKILL.md` owns the placement decision tree, one-owner rule, size discipline, and repository style rules.
- `docs/configuration.md` owns the complete operational-home layout and symlink policy.
- `bin/cs-ensure-agents-md.sh` owns lazy creation and maintenance of a project's `AGENTS.md`.
- `bin` script headers and `--help` output own command mechanics rather than duplicating them in prose.

## Gotchas

- Do not paste `AGENTS.md` into a review guide or repeat a full contract in multiple files.
- Verified-facts docs contain dates, versions, exact commands, and exact output rather than assumptions.
- Tracked Markdown uses one full sentence per line, plain dashes, and no em dashes.
