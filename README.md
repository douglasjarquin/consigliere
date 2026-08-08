# Consigliere

<img width="1774" height="887" alt="consigliere-github-banner" src="https://github.com/user-attachments/assets/0560ad7b-aada-4bb6-a438-cc756cb1a4ea" />

A personal agent distro: launch codex or claude in this repo and it becomes the consigliere - the boss's single point of contact for all software work, delegating everything to autonomous soldiers it spawns, supervises, and lands work from.

Consigliere is a from-scratch personal rewrite of [Firstmate](https://github.com/kunchenguid/firstmate) built for two harnesses (**codex** and **claude**) and one terminal runtime (**herdr**), leaning on their native features instead of generic multi-backend shims. Soldiers inherit the root session's harness, so one consigliere works wherever you work (codex at home, claude at work):

- herdr-native worktrees (workspace-per-task) replace the treehouse pool
- herdr-native agent status replaces pane-regex busy detection
- one thin harness layer (`bin/cs-harness-lib.sh`), one supervision protocol (bounded foreground checkpoint), one Stop-hook backstop
- ~9k lines of bash instead of firstmate's ~29k

## Quick start

Requirements: `codex` or `claude`, `herdr` (protocol >= 16), `jq`, `git`, `gh` + `gh-axi` (authenticated).
Optional: the other harness, `tasks-axi` (backlog), `no-mistakes` (delivery pipeline), `lavish-axi`, `chrome-devtools-axi`, `quota-axi`.

1. **Clone the repo.**

   ```
   git clone https://github.com/douglasjarquin/consigliere.git
   ```

2. **Install herdr.** Either use your own install, or take CI's pinned, SHA-256-verified build (`bin/cs-install-herdr.sh` is the single owner of that pin; `docs/herdr.md` documents it):

   ```
   bin/cs-install-herdr.sh ~/.local/bin
   ```

3. **Install the rest** - `jq`, `git`, `gh`, `gh-axi`, and at least one harness (`codex` or `claude`) - then authenticate GitHub:

   ```
   gh auth login
   ```

4. **Check the machine.** `bin/cs-doctor.sh` reports every dependency, its version, the herdr server, and GitHub auth, and suggests an install channel for each gap. An installed axi tool below its version floor counts as a gap here, exactly as it does at session start. It only checks - it never installs anything, since the same tool arrives by brew, npm, or a native installer depending on the machine:

   ```
   bin/cs-doctor.sh
   ```

   It exits nonzero while any required dependency or service check is failing.

5. **Start the herdr server** (consigliere spawns every soldier into a herdr workspace, so this comes first - without it the session refuses to dispatch):

   ```
   herdr
   ```

6. **From inside a herdr pane, enter the repo and launch the harness:**

   ```
   cd consigliere
   codex     # or: claude
   ```

7. **Let the first session settle.** It runs `bin/cs-session-start.sh` and reports anything still missing, out of date, or unauthenticated (the same required/optional inventory and version floors `cs-doctor.sh` reads). It detects only - it asks before installing anything.

8. **Give it a project.** Consigliere never works a repo it does not know about; tell it to add or create one (it owns the clone into `projects/`, the registry entry, and the project's standing delivery posture - each task's actual delivery mode is decided when the work is dispatched).

## Use

```
herdr                 # the terminal runtime; soldiers live in its workspaces
cd consigliere
codex                 # or: claude
```

`AGENTS.md` is the always-loaded operating contract (claude loads it via the `CLAUDE.md` symlink). The session starts with `bin/cs-session-start.sh`, which prints one ordered digest of the whole operating picture; its header owns the section order and contents. The root harness is auto-detected (`CLAUDECODE=1` ⇒ claude, else codex; `host/harness.conf` overrides).

Then talk to it in plain language: describe the work, name the project when it is ambiguous, and it dispatches, supervises, and brings back PRs for your word. It never merges without you - `yolo` lets it answer routine review decisions on its own, but landing is always your call - never writes to a project itself, and never tears down unlanded work.

## Layout

- `bin/` - `cs-*` scripts; read each header before first use (`bin/cs-doctor.sh` for a dependency preflight)
- `skills/` - agent-loaded procedures (afk, rundown, the-books, vault, capo-provisioning, upstream-review, ...)
- `docs/` - architecture, configuration schema (owner), supervision protocol, verified herdr/codex/claude/lavish facts
- `tests/` - colocated behavior tests (`bash tests/<name>.test.sh`, or `bin/cs-test-run.sh --portable`; live suites opt in via `CS_TEST_HERDR_LIVE=1` / `CS_TEST_CODEX_LIVE=1`)
- `config/` - the user-owned tree (settings and durable memory), boss-private and gitignored; back it up wholesale
- `host/` - machine-local sibling (capo roster, harness pin, activation); never backed up, re-created per machine
- `data/ state/ projects/` - generated output, volatile runtime state, and clones; boss-private, gitignored, disposable or re-creatable

Backup and restore need no tool:

```
back up:      cp -a <home>/config <backup>/          # no exclusions
new machine:  cp -a <backup>/config <newhome>/config
              then fill in host/ for this machine and run bin/cs-doctor.sh
```

## CI

`.github/workflows/ci.yml` runs required checks on pushes to `main` and PRs into
`main`, with least-privilege `contents: read` and cancellation of superseded
runs. CI and local runs share the same repository-owned entrypoints, so hosted
checks cannot drift from what you run before pushing:

| Hosted check | Reproduce locally |
| --- | --- |
| Shell lint | `CI=true bin/cs-lint.sh` (single owner of the file set, config, and pinned ShellCheck version; `--required-version` prints the pin). A plain local `bin/cs-lint.sh` lints only the canonical-set files changed since the merge-base with `origin/main`, plus both directions of the source graph around them - the libraries a changed file sources, and the canonical files that source a changed file, since ShellCheck blames a broken library contract on its consumers - so parallel lanes do not each re-lint the whole tree. That graph is built from the repo's own `# shellcheck source=` directives, and `tests/cs-ci-contract.test.sh` fails the build when a source site in the canonical set has no directive, so the graph cannot go stale; CI, the default branch, and a branch with no merge-base always lint the full set |
| Portable behavior | `bin/cs-test-run.sh --portable` (every hermetic test, serial) |
| Real Herdr behavior | `CS_TEST_HERDR_LIVE=1 bin/cs-test-run.sh --herdr` (needs a real herdr + a running default session for the lab tripwire) |
| Repo invariants | `git ls-files -- .env data state config host projects .no-mistakes` prints nothing; tracked symlinks stay symlinks |
| Coverage guard | `bin/cs-test-run.sh --check-coverage` (proves every `tests/*.test.sh` is in exactly one lane) |

Each lane except repo invariants runs only when the change can affect it.
`bin/cs-ci-lanes.sh` owns the path-to-lane map and prints the decision for a diff
(`bin/cs-ci-lanes.sh <base> <head>`, or `--paths-from -` for a path list).
Repo invariants stay unconditional, because any commit can track a boss-private
path or flatten a tracked symlink.
The gate is a job-level `if:` rather than a `paths:` filter, so a skipped lane
still reports its check instead of hanging pending, and an undeterminable change
set (force-push, first push, shallow clone) fails open and runs everything.

Pinned-tool owners: ShellCheck version in `bin/cs-lint.sh`; herdr version in
`bin/cs-install-herdr.sh` (documented in `docs/herdr.md`); herdr protocol floor
in `bin/cs-herdr-lib.sh` (`CS_HERDR_MIN_PROTOCOL`), which the installer reads.
The axi-family version floors (`gh-axi`, `tasks-axi`, `lavish-axi`, `quota-axi`) and their bump policy live in `bin/cs-deps-lib.sh`, which both `bin/cs-doctor.sh` and session start gate on.
Every `tests/*.test.sh` belongs to one lane - `portable`, `real-herdr`, or the
opt-in `live-codex` (`CS_TEST_CODEX_LIVE=1`, never run in hosted CI and reported
as visibly excluded by the coverage guard). The workflow contract is protected
by `tests/cs-ci-contract.test.sh`.

## Upstream

Firstmate improvements are ported editorially through `/upstream-review` (`bin/cs-upstream-log.sh` + the tracked ledger `docs/upstream-review.md`); never merged, never cherry-picked.
