# Consigliere

A personal agent distro: launch codex or claude in this repo and it becomes the consigliere - the boss's single point of contact for all software work, delegating everything to autonomous soldiers it spawns, supervises, and lands work from.

Consigliere is a from-scratch personal rewrite of [Firstmate](https://github.com/kunchenguid/firstmate) built for two harnesses (**codex** and **claude**) and one terminal runtime (**herdr**), leaning on their native features instead of generic multi-backend shims. Soldiers inherit the root session's harness, so one consigliere works wherever you work (codex at home, claude at work):

- herdr-native worktrees (workspace-per-task) replace the treehouse pool
- herdr-native agent status replaces pane-regex busy detection
- one thin harness layer (`bin/cs-harness-lib.sh`), one supervision protocol (bounded foreground checkpoint), one Stop-hook backstop
- ~9k lines of bash instead of firstmate's ~29k

## Use

```
cd consigliere
codex     # or: claude
```

`AGENTS.md` is the always-loaded operating contract (claude loads it via the `CLAUDE.md` symlink). The session starts with `bin/cs-session-start.sh` (one digest: lock, bootstrap, wake queue, context, fleet state, supervision block). The root harness is auto-detected (`CLAUDECODE=1` ⇒ claude, else codex; `config/harness` overrides).

Requirements: `codex` or `claude`, `herdr` (protocol >= 16), `jq`, `gh` + `gh-axi` (authenticated). Optional: the other harness, `tasks-axi` (backlog), `no-mistakes` (delivery pipeline), `lavish-axi`, `chrome-devtools-axi`.

## Layout

- `bin/` - `cs-*` scripts; read each header before first use
- `skills/` - agent-loaded procedures (afk, rundown, the-books, stow, capo-provisioning, upstream-review, ...)
- `docs/` - architecture, configuration schema (owner), supervision protocol, verified herdr/codex/claude facts
- `tests/` - colocated behavior tests (`bash tests/<name>.test.sh`, or `bin/cs-test-run.sh --portable`; live suites opt in via `CS_TEST_HERDR_LIVE=1` / `CS_TEST_CODEX_LIVE=1`)
- `data/ state/ config/ projects/` - boss-private operational home, gitignored

## CI

`.github/workflows/ci.yml` runs required checks on pushes to `main` and PRs into
`main`, with least-privilege `contents: read` and cancellation of superseded
runs. CI and local runs share the same repository-owned entrypoints, so hosted
checks cannot drift from what you run before pushing:

| Hosted check | Reproduce locally |
| --- | --- |
| Shell lint | `bin/cs-lint.sh` (single owner of the file set, config, and pinned ShellCheck version; `--required-version` prints the pin) |
| Portable behavior | `bin/cs-test-run.sh --portable` (every hermetic test, serial) |
| Real Herdr behavior | `CS_TEST_HERDR_LIVE=1 bin/cs-test-run.sh --herdr` (needs a real herdr + a running default session for the lab tripwire) |
| Repo invariants | `git ls-files -- .env data state config projects .no-mistakes` prints nothing; tracked symlinks stay symlinks |
| Coverage guard | `bin/cs-test-run.sh --check-coverage` (proves every `tests/*.test.sh` is in exactly one lane) |

Pinned-tool owners: ShellCheck version in `bin/cs-lint.sh`; herdr version in
`bin/cs-install-herdr.sh` (documented in `docs/herdr.md`); herdr protocol floor
in `bin/cs-herdr-lib.sh` (`CS_HERDR_MIN_PROTOCOL`), which the installer reads.
Every `tests/*.test.sh` belongs to one lane - `portable`, `real-herdr`, or the
opt-in `live-codex` (`CS_TEST_CODEX_LIVE=1`, never run in hosted CI and reported
as visibly excluded by the coverage guard). The workflow contract is protected
by `tests/cs-ci-contract.test.sh`.

## Upstream

Firstmate improvements are ported editorially through `/upstream-review` (`bin/cs-upstream-log.sh` + `data/upstream-review.md`); never merged, never cherry-picked.
