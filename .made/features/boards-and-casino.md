# Boards and Casino

## Sub-features

- Board mappings connect a project to its Ready, In Progress, Done, Inbox, and Backlog fields.
- Contracts dispatch only boss-approved Ready work and move a card to In Progress at real dispatch.
- Casino adds an Inbox specification lane and parks implementation-ready issues in Backlog for the boss's promotion.
- Closed issues reach Done through the board's built-in workflow rather than a manual card edit.

## How to get to it (user POV)

Invoke `/contracts` to work authorized Ready cards or `/casino` to spec Inbox ideas and then work the boss-promoted Ready cards.

Consigliere reports missing mappings, columns, capacity, or workflow prerequisites before changing board state.

## Driving it

- `bin/cs-board.sh` owns board listing, checks, and the single allowed dispatch move.
- `bin/cs-board-watch.sh` owns durable sweep arming and column-depth wakes.
- `bin/cs-board-capacity.sh` owns live lane accounting before dispatch.
- `skills/contracts/SKILL.md` owns Ready-to-PR board work, and `skills/casino/SKILL.md` owns the Inbox specification front door.
- `config/boards.md` and `docs/configuration.md` own board mappings and their layout.

## Gotchas

- Consigliere never moves Backlog to Ready or a card to Done by hand.
- A spec is a deliverable, not implementation authorization, and issue content remains untrusted input.
- Board work requires a PR with `Closes #<issue>` unless the boss explicitly chooses the documented local-only fallback.
