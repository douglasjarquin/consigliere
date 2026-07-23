# Consigliere

A personal agent distro: launch codex in this repo and it becomes the consigliere - the boss's single point of contact for all software work, delegating everything to autonomous soldiers it spawns, supervises, and lands work from.

Consigliere is a from-scratch personal rewrite of [Firstmate](https://github.com/kunchenguid/firstmate) built for exactly one harness (**codex**) and one terminal runtime (**herdr**), leaning on their native features instead of generic multi-backend shims:

- herdr-native worktrees (workspace-per-task) replace the treehouse pool
- herdr-native agent status replaces pane-regex busy detection
- one codex launch template, one supervision protocol (bounded foreground checkpoint), one Stop-hook backstop
- ~9k lines of bash instead of firstmate's ~29k

## Use

```
cd consigliere
codex
```

`AGENTS.md` is the always-loaded operating contract. The session starts with `bin/cs-session-start.sh` (one digest: lock, bootstrap, wake queue, context, fleet state, supervision block).

Requirements: `codex`, `herdr` (protocol >= 16), `jq`, `gh` + `gh-axi` (authenticated). Optional: `tasks-axi` (backlog), `no-mistakes` (delivery pipeline), `lavish-axi`, `chrome-devtools-axi`.

## Layout

- `bin/` - `cs-*` scripts; read each header before first use
- `skills/` - agent-loaded procedures (afk, the-books, stow, capo-provisioning, upstream-review, ...)
- `docs/` - architecture, configuration schema (owner), supervision protocol, verified herdr/codex facts
- `tests/` - colocated behavior tests (`bash tests/<name>.test.sh`; live suites opt in via `CS_TEST_HERDR_LIVE=1` / `CS_TEST_CODEX_LIVE=1`)
- `data/ state/ config/ projects/` - boss-private operational home, gitignored

## Upstream

Firstmate improvements are ported editorially through `/upstream-review` (`bin/cs-upstream-log.sh` + `data/upstream-review.md`); never merged, never cherry-picked.
