# codegraph verified facts

Verified against codegraph 1.5.0 (`@colbymchenry/codegraph`, npm global) on 2026-08-13, in this consigliere worktree and in a scratch clone of `pinchos` under `/tmp` (never against a `projects/*` primary checkout).
Re-verify after a codegraph upgrade; `bin/cs-spawn.sh`'s `spawn_codegraph_prep` gates on binary presence only, not version.
This supersedes the retired `graft` integration (PR #72, PR #83): the boss invalidated graft entirely in favor of codegraph, "which is what the lazy coding harnesses use."

## Wiring is global, not per-repo

`codegraph install` auto-configures each agent's MCP wiring (Claude Code, Codex CLI, Cursor, opencode, and more) by writing to that agent's own GLOBAL config - `~/.claude.json`'s `mcpServers.codegraph` block for Claude Code, `~/.codex/config.toml`'s `[mcp_servers.codegraph]` table for Codex - not to any project-local file.
This is already done on this machine for both harnesses (confirmed via `codegraph install --print-config <agent>`, a read-only dry-run, matching the live global config verbatim).
Two reference repos on this machine that already integrate codegraph (`/Users/douglasjarquin/github/oss/lazyclaudecode`, `/Users/douglasjarquin/github/oss/lazycodex`) confirm the same shape: neither commits a project-local `.mcp.json` or `.claude/settings.json` entry for codegraph - `lazyclaudecode` has no codegraph wiring at all (a stale pre-codegraph snapshot), and `lazycodex`'s wiring lives entirely inside its own packaged Codex plugin, never in a target repo's own tracked files.
Consigliere therefore commits no project-local MCP or hook wiring for codegraph either, matching that precedent instead of inventing a per-repo copy of what a one-time global `codegraph install` already provides.

## Storage: per-path, not centrally shared by default

A direct `codegraph init <path>` (the CLI invoked exactly as `spawn_codegraph_prep` calls it) creates `.codegraph/` **inside the target directory itself** - a `codegraph.db` SQLite file plus codegraph's own `.codegraph/.gitignore` (`*` then `!.gitignore`), which covers only its own directory and never touches the project root's `.gitignore`.
This is a different storage model from the `omo` Codex plugin's own wrapped worker (`packages/omo-codex/plugin/components/codegraph/`), which centralizes indexes at `~/.omo/codegraph/projects/<name>-<hash>/` and symlinks `.codegraph` at the project root to that store - confirmed by consigliere's own primary checkout, where `.codegraph` is exactly such a symlink (`~/.omo/codegraph/projects/consigliere-cd5ddb39611a3586`).
Either way, **the index is keyed to one absolute path** - confirmed empirically: the central store holds three independent `firstmate-*` hash directories, one per distinct checkout/worktree location, each with its own database, and no automatic sharing across paths.
A fresh task worktree at a new path therefore never inherits the primary checkout's index on its own - the exact problem the retired graft integration solved for graft, and the reason this feature exists for codegraph too.

One operational fact worth recording because it directly affects the primary's own state, not just worktrees: consigliere's own primary `.codegraph` symlink is currently **dangling** (its target directory does not exist in `~/.omo/codegraph/projects/` today), so `spawn_codegraph_prep`'s own primary-index check (`-f "$PROJ_ABS/.codegraph/codegraph.db"`) correctly reports "no index" and silently no-ops until someone re-runs `codegraph init` at the primary.

## `codegraph init` is idempotent by itself

Unlike graft (whose `build` needed an idempotence argument from its own incremental content-hash cache), codegraph's `init` checks first and short-circuits:

```
$ codegraph init "$(pwd -P)"        # first run
◆  Indexed 4 files
●  20 nodes, 34 edges in 112ms
0.322 total

$ codegraph init "$(pwd -P)"        # second run, same path
▲  Already initialized in ...
●  Use "codegraph index" to re-index or "codegraph sync" to update
0.103 total
```

`spawn_codegraph_prep` therefore needs no existence guard of its own before calling `codegraph init` - a relaunch re-running the same call is already cheap.

## An interrupted init leaves an unusable index, and a re-run will not repair it

Idempotence covers only a *completed* init.
Killing `codegraph init`'s process group mid-run - exactly what `cs_run_timed` does when `CS_SPAWN_CODEGRAPH_TIMEOUT_SECS` expires (`bin/cs-timeout-lib.sh`) - leaves `.codegraph/codegraph.lock` beside a truncated database.
`codegraph status` then reports that the last index run never finished and the index is truncated, and `codegraph unlock --help` states a stale lock blocks indexing.
A later `codegraph init` at that path prints "Already initialized" and repairs nothing, so nothing in codegraph's own CLI clears the state on its own.

`spawn_codegraph_prep` therefore removes `<worktree>/.codegraph` when its own `codegraph init` fails or times out **and** the worktree had no `.codegraph` before that call.
Fail-open then means no index rather than a broken one, and the next prep run - a relaunch - rebuilds from scratch.
An index the worktree already carried is never removed on failure: that one came from a completed earlier run, and the warning says so instead of claiming the worktree has no index.

The removal itself is best-effort, and deliberately so: `bin/cs-spawn.sh` runs under `set -eu`, the prep step sits after the worktree exists and before the launch line is delivered, so a removal that exited non-zero would abort the whole spawn.
That is not hypothetical - codegraph runs work outside the launching process group (a `codegraph ... serve --mcp` process observed on this machine with PPID 1 and its own PGID), so the timeout's group kill does not necessarily stop everything writing under `<worktree>/.codegraph`, and a removal walking a tree that is still being written can fail.
When the leftover survives, the warning names it (`a half-written codegraph index remains at ...`) instead of claiming a clean worktree.

## Committed-ignore guard: both rule forms have to be asked for

Git's ignore matching against a path that does not exist yet - which is every fresh task worktree - depends on the trailing slash on BOTH sides.
Verified empirically against scratch fixture repos:

| committed rule | `check-ignore .codegraph` | `check-ignore .codegraph/` |
| --- | --- | --- |
| `.codegraph` | ignored | ignored |
| `.codegraph/` | NOT ignored | ignored |

So a bare query alone silently reports "not ignored" for any project carrying the conventional directory-only rule, which is the form codegraph's own README names.
`spawn_codegraph_prep` therefore asks both ways and treats either answer as a pass, bare form first: when a `.codegraph` symlink already exists at the queried path, the trailing-slash query hard-errors with `fatal: pathspec '.codegraph/' is beyond a symbolic link`, and the bare query already covers that case.
Graft's retired guard queried the slash form only, which covers both rule forms but breaks on that already-existing-symlink case; asking both ways covers both axes.

## Coverage gap: no bash extractor either

Consigliere's own index covers exactly 2 Python files and 2 YAML files (4 total) out of roughly 90 shell scripts - the same shape of gap graft had, just a different pair of covered languages.
The fleet projects that benefit today are the ones with indexable source: `pinchos` (18 swift files indexed) and presumably `niceuptime`/`nicebaas` (TypeScript, not independently measured here).

## Measured init timings (2026-08-13, codegraph 1.5.0)

**consigliere** (this task worktree, cold - no prior `.codegraph/` present):

```
$ codegraph init "$(pwd -P)"
◆  Indexed 4 files
●  20 nodes, 34 edges in 112ms
0.322 total

$ codegraph init "$(pwd -P)"     # already-initialized re-run
▲  Already initialized
0.103 total
```

**pinchos** (fresh scratch clone at `/tmp/codegraph-timing-pinchos-scratch`, genuinely cold - 18 swift files + 1 yaml):

```
$ git clone --quiet https://github.com/douglasjarquin/pinchos.git /tmp/codegraph-timing-pinchos-scratch
$ cd /tmp/codegraph-timing-pinchos-scratch
$ codegraph init "$(pwd -P)"
◆  Indexed 19 files
●  177 nodes, 301 edges in 106ms
0.294 total

$ codegraph init "$(pwd -P)"     # already-initialized re-run
▲  Already initialized
0.100 total
```

No project registered in `config/projects.md` carried a built codegraph index at measurement time, so this used consigliere plus a scratch clone, the same pattern the retired graft measurement used.

## `CS_SPAWN_CODEGRAPH_TIMEOUT_SECS` default

The slowest measured cold init above is consigliere's own 0.322s.
Four times that is ~1.3s, well under the 10s floor the retired graft feature established for the equivalent knob, so the shipped default here is the same **10** (`CS_SPAWN_CODEGRAPH_TIMEOUT_SECS=10`) - not scaled up from these two small fixtures, since a real fleet repo with far more indexable files could plausibly need more of that floor's headroom.
