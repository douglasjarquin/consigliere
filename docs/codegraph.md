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

## Committed-ignore guard: simpler than graft's

Graft's committed-ignore guard needed a trailing-slash query (`graft/`, not `graft`) because git's directory-only ignore patterns only match a bare non-existent path when the pattern itself ends in `/`.
`.codegraph` carries no trailing slash in either the ignore rule or the guard's query, and a plain (non-directory-only) pattern matches a not-yet-existing path correctly either way - verified empirically against a scratch fixture repo before shipping, so this guard needed no equivalent workaround.

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
