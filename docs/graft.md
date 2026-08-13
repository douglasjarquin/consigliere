# graft verified facts

Verified against graft 0.10.0 (`@nanonets/graft`, npm global, source `github.com/NanoNets/context-graph-engine`) on 2026-08-13, in this consigliere worktree and in a scratch clone of `pinchos` under `/tmp` (never against a `projects/*` primary checkout).
Re-verify after a graft upgrade; `bin/cs-spawn.sh`'s `spawn_graft_prep` gates on binary presence only, not version.

## Seeding mechanics

Index lives in-repo at `<repo>/graft/`, gitignored by design (a local, regenerable cache, like `node_modules`); there is no central store.
Graft's own `dist/graph/seed.js` `seedGraph` already detects a linked worktree via its `gitdir:` file, copies the parent checkout's query graph plus three `.cache` sidecars in, and lets the ordinary refresh gate repair the commit-diff drift - copy-not-symlink is deliberate, because file:line spans are per-tree (seed.js:18-20).
Seeding runs from both `refresh` (refresh.js:116) and `build` (build.js:107-111, preserving paid `--deep` summaries), and no-ops when the worktree already has its own wiring (`ensureFreshGraph` gates on `!existsSync(wiringPath(outDir))`).

Seeding alone is not enough for this feature: **it copies only the query graph, never the markdown** (seed.js:127-137).
Only `graft build` produces `INDEX.md` and the per-file cards, and the boss asked for a worktree with the index "init and built" - the full surface, not just the query sidecars.
That is why `spawn_graft_prep` calls `graft build`, never a bare `graft check`/`graft ask`.

## The `--dir` trap

`--dir` disables seeding entirely (seed.js:204: `if (opts.contextDir || seedDisabled()) return NOT_SEEDED`).
`spawn_graft_prep` calls `graft build <worktree-root>` positionally and never with `--dir`, confirmed against real output below.

## The gitignore writer

`graft build` calls `ensureGitignored`/`ensureSearchable` (build.js:272, `dist/context/node-file.js:69-91`), which WRITE `.gitignore`/`.ignore` into the build root whenever its own entries are absent.
Two consequences verified live in this repo (`.no-mistakes/evidence/task-2-writerproof.txt`):

- The writer matches only the literal string `graft/`, so an *anchored* `/graft/` gitignore fix self-reverts on the next `graft build` at the repo root - the writer just re-appends the unanchored form, and last-match-wins re-ignores anything an anchored fix was trying to un-ignore (this is why `.gitignore` keeps `graft/` unanchored and adds `!skills/graft/` after it, rather than anchoring).
- `git check-ignore` on a *directory-only* pattern like `graft/` only matches a bare `graft` query (no trailing slash) when that path already exists on disk - which a fresh task worktree never does. `spawn_graft_prep`'s committed-ignore guard therefore queries `graft/` (trailing slash), not `graft`, so it works correctly on the exact worktrees this feature targets, not just on ones that already happen to have a `graft/` directory.

Because a soldier's very first turn must never start with a dirty tree from this writer, `spawn_graft_prep` only invokes `graft build` when the worktree's own COMMITTED rules already ignore `graft/`; otherwise it warns and skips.

## Coverage gap: no bash extractor

Graft's depth tier covers ts/js/py/go; the breadth tier adds swift/rust/java/etc; there is no `.sh` extractor.
Consigliere's own index therefore covers the Python files in `bin/` (`cs-detach.py`; `cs-herdr-events.py` was the second until the event transport moved onto herdr's plugin hooks) out of roughly 90 shell scripts - the measurement below was taken while both existed.
The fleet projects that actually benefit from this feature today are the ones with indexable source: `pinchos` (swift) and `niceuptime`/`nicebaas` (ts).
Upstream extractor work for shell is out of scope for this feature.

## Measured build timings (2026-08-13, graft 0.10.0)

**consigliere** (this task worktree; already carries a seeded query graph copied from the primary at `/Users/douglasjarquin/github/consigliere`, so this is a warm-seed, cold-parse measurement of a tiny 2-file python index):

```
$ rm -rf graft
$ time env -u GRAFT_API_KEY graft build "$(pwd -P)"
✓ wiring: 9 nodes (7 function, 2 file), 21 edges, 2 cards [python]
  parsed: 0 of 2 files (2 replayed from cache)
  seeded: copied a starting graph from /Users/douglasjarquin/github/consigliere (git worktree)
0.152 total

$ time env -u GRAFT_API_KEY graft build "$(pwd -P)"     # immediate rebuild, no changes
✓ wiring: 9 nodes (7 function, 2 file), 21 edges, 2 cards [python]
  parsed: 0 of 2 files (2 replayed from cache)
0.144 total
```

**pinchos** (fresh scratch clone at `/tmp/graft-timing-pinchos-scratch`, no seeded graph available - a genuinely cold parse of 18 swift files):

```
$ git clone --quiet https://github.com/douglasjarquin/pinchos.git /tmp/graft-timing-pinchos-scratch
$ cd /tmp/graft-timing-pinchos-scratch
$ time env -u GRAFT_API_KEY graft build "$(pwd -P)"
✓ wiring: 239 nodes (135 variable, 67 function, 18 file, 18 class, 1 interface), 0 edges, 18 cards [swift]
  parsed: 18 of 18 files (0 replayed from cache)
0.567 total

$ time env -u GRAFT_API_KEY graft build "$(pwd -P)"     # immediate rebuild, no changes
✓ wiring: 239 nodes (135 variable, 67 function, 18 file, 18 class, 1 interface), 0 edges, 18 cards [swift]
  parsed: 0 of 18 files (18 replayed from cache)
0.225 total
```

No project registered in `config/projects.md` (`pinchos`, `niceuptime`, `nicebaas`) carried a built graft index at measurement time, so this used consigliere plus a scratch clone rather than an existing fleet index; this matches upstream's own README claim of sub-second, content-hash-cached builds (README:180).

## `CS_SPAWN_GRAFT_TIMEOUT_SECS` default

The slowest measured cold build above is pinchos's 0.567s.
Four times that is ~2.3s, well under the 10s floor `bin/cs-spawn.sh`'s task plan set for this knob, so the shipped default is **10** (`CS_SPAWN_GRAFT_TIMEOUT_SECS=10`), not a value scaled off the measurement - a real fleet repo with thousands of indexable files could plausibly need more of that floor's headroom than these two small fixtures show.
