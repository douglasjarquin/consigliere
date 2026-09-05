# Boards and casino

Board-driven work: spec raw Inbox ideas, park them for the boss, and ship only what the boss moves to Ready.

## Sub-features

- contracts sweep: pull Ready issues, move each card to In Progress at dispatch, and land a PR that `Closes #<n>`.
- casino factory: spec Inbox into implementation-ready issues, park them in Backlog, then run the same Ready sweep.
- two human gates: only the boss moves Backlog to Ready, and only the boss merges the PR.
- durable watch: an armed sweep keeps watching the columns after this conversation ends.

## How to get to it (user POV)

The boss names a project and asks to work the Ready column, or to run the factory on Inbox.
Consigliere fills a few lanes, keeps pulling as they free, and tells the boss which specs now wait in Backlog.
Merging the PR is what moves the card to Done through the board's own closed-to-Done workflow.

## Driving it

- `skills/contracts/SKILL.md` owns the Ready sweep; `skills/casino/SKILL.md` owns the Inbox spec lane in front of it.
- `bin/cs-board.sh` lists and moves cards; `bin/cs-board-watch.sh` arms the durable sweep; `bin/cs-board-capacity.sh` owns live lane accounting.
- `config/boards.md` maps the project to its GitHub board; `docs/configuration.md` owns the line format.

## Gotchas

- Consigliere never moves Backlog to Ready and never sets Done itself.
- Arm the sweep before listing, or a column that refills after this session goes unnoticed.
- Default three lanes per project, five under the boss-selected Nice Uptime policy; serialize only true dependencies.
- A `local-only` project cannot close an issue by merge; confirm the close path before sweeping.
