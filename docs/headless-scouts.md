# Headless scouts: decision and end-to-end trace

Status: **FINISHED (signed off).** The safe wiring (docs + fleet-view labeling)
and the watcher refinement both landed: `bin/cs-watch.sh` now recognizes a live
headless scout (`pane_is_headless`) and skips its stale triage until it reports a
terminal `done:`/`failed:`, so it no longer raises a spurious "went quiet" wake
while working non-interactively (tests in `tests/cs-watch-triage.test.sh`). A live
headless run writes no status until exit, so the signal path never fires for it;
completion still surfaces via the terminal status wake.

A `--headless` scout runs the brief non-interactively (`codex exec` / `claude -p`)
as a cheap fire-and-forget investigation that does not hold a supervised
interactive pane. Spawn implements it fully, but before this change no
supervision or observability code read the `headless=1` marker, and the docs
still called it "planned." This document traces the capability end to end,
records what is already correct, what was merely cosmetic, and recommends
finishing rather than removing the flag.

> Line references are verified against the plan's base commit `55aa94e` (this
> worktree). Anchor by **content**, not by line number, when reading a later
> tree: `bin/cs-spawn.sh`, `bin/cs-teardown.sh`, and `bin/cs-classify-lib.sh`
> have shifted line numbers on `main` (the operational-input / spawn-lock work
> and the open-decision cursor fold landed after `55aa94e`); `bin/cs-watch.sh`
> line numbers match.

## End-to-end trace: `cs-spawn.sh <id> <proj> --scout --headless`

1. **Flag parse** — `bin/cs-spawn.sh:94` `--headless) HEADLESS=1`. Scout-only
   guard at `:121-123`: `--headless` on a non-scout task exits 2.

2. **Metadata** — `bin/cs-spawn.sh:238`
   `[ "$HEADLESS" -eq 1 ] && META_LINES+=("headless=1")`. So `state/<id>.meta`
   carries `headless=1` alongside the ordinary `kind=scout` row. Documented at
   `docs/configuration.md:38`.

3. **Launch (the fork)** — `bin/cs-spawn.sh:246-252` (headless branch) vs
   `:253-267` (interactive branch). The headless branch passes the status-file
   path and calls `cs_harness_scout_launch`; crucially it wires **no**
   `state/<id>.turn-ended` hook (no codex `-c notify=`, no claude `--settings`
   Stop hook). The interactive branch is the only one that wires turn-end.

4. **The launch string** — `bin/cs-harness-lib.sh:248-261`
   (`cs_harness_scout_launch`): builds
   `if codex exec …; then echo 'done: headless scout finished; read the report' >> <status>; else echo "failed: … exited $?" >> <status>; fi`
   (`codex exec` for codex, `claude -p` for claude). Run in the task pane via
   `cs_herdr_run` (`bin/cs-spawn.sh:269`).

5. **Process exit is the turn end** — on exit the launch line appends the
   terminal `done:`/`failed:` line to `state/<id>.status`. A headless scout
   **never** touches `state/<id>.turn-ended`.

### Does the watcher see completion? YES.

- **Signal scan** — `bin/cs-watch.sh:459-469` (`scan_signals`) loops
  `for f in "$STATE"/*.status "$STATE"/*.turn-ended` and tolerates the missing
  `turn-ended` file (`:462` `[ -e "$f" ] || continue`). The `done:`/`failed:`
  append changes `<id>.status`, producing a signal wake.
- **Actionability** — `bin/cs-watch.sh:1089` surfaces when
  `signal_reason_is_actionable` is true. That predicate
  (`bin/cs-classify-lib.sh:300-310`) calls `status_is_boss_relevant`
  (`:103-119`), and `done`/`failed` are **terminal boss verbs** (`:115`,
  `:88-96`), so the wake surfaces with no headless-specific classification.

**Conclusion: a headless scout's completion is detected today, exactly as the
spawn comment (`bin/cs-spawn.sh:247-250`) claims. The plan's "completion NOT
detected" STOP condition does not fire.**

### What assumes an interactive pane (inert or merely cosmetic)

- **Fleet view (was cosmetic, now fixed here)** — `bin/cs-fleet-view.sh`
  `task_json_stream` reads `kind`, optional `mode/yolo`, `pane`, and other fields, but did not read `headless`,
  and rendered the endpoint column as `present / <agent>`, implying a steerable
  pane. Fixed: it now reads `headless`, emits it in the `cs-fleet-view.v1`
  snapshot, and the human render appends `· headless (not steerable)` to the
  endpoint (`tests/cs-fleet-view.test.sh` asserts both).
- **Watcher stale-pane loop (inert-to-noisy; the deferred risk)** —
  `bin/cs-watch.sh:1122-1287` iterates `recorded_panes`, which includes the
  headless scout's pane. `pane_kind` (`:1123`) returns `scout`; only `capo` is
  special-cased (`:1132`, `:1171`), so a headless scout runs the same stale
  triage as a ship. Two sub-cases:
  - Already `done:` + idle pane → `stale_is_terminal` (`:1183`) true → surfaces
    completion (redundant with the signal wake, deduped by markers). Correct.
  - Mid-run but not detected busy (a non-interactive `codex exec` presents no
    TUI busy banner) → the non-terminal-stale path may reach
    `surface_nonterminal_stale` (`:1247`) and raise a spurious "went quiet"
    heartbeat wake while the scout is legitimately working. `cs-crew-state.sh`
    for `kind=scout` skips the run-step read (`:42`) and falls back to
    `crew_pane_is_busy` (`:579`) / the log, so it may not recognize a live
    headless exec as working. **This is noisy, not broken:** the watcher only
    **wakes consigliere**; it never sends text to the pane, so there is no
    automated mis-steer of a headless run.
- **Teardown (already correct)** — `bin/cs-teardown.sh`: `kind=scout` carves out
  of the worktree-cleanliness safety check (`:279-281` `capo|scout) return 0`),
  still requires a report and the unresolved-decision completion gate
  (`:393-403`), and skips fleet-sync (`:466`). A headless scout is `kind=scout`,
  so teardown handles it identically to an interactive scout. No headless-
  specific work needed.

## Recommendation: FINISH

The expensive, subtle part — turn-end completion detection — **already works by
design**: the terminal `done:`/`failed:` status append flows through the
ordinary signal path and surfaces as a boss-relevant terminal wake, independent
of the missing `turn-ended` marker. What remains is modest:

- surface polish (fleet-view labeling + docs) — **done in this change, low risk**;
- one MED-risk watcher refinement so a mid-run headless pane is not mistaken for
  an interactive pane that "went quiet" — **gated on sign-off**.

Because completion works and the residual defects are cosmetic-to-noisy,
removing the flag would discard a working, intended capability (cheap parallel
scouts, valuable to a solo operator running many at once) to avoid a small,
well-scoped watcher change. Finish is the better direction.

## Downstream changes

### Done in this change (low-risk, no supervision/steer behavior touched)

- [x] `bin/cs-fleet-view.sh` — read `headless` from meta, emit it in the
  `cs-fleet-view.v1` snapshot, and label the endpoint so it never implies a
  steerable pane. (Risk: LOW — pure read-only rendering.)
- [x] `tests/cs-fleet-view.test.sh` — a headless-scout fixture asserts the
  labeled row and `headless:true` in `--json`; the interactive scout row stays
  unlabeled. (Risk: LOW.)
- [x] `docs/codex.md:35` — "planned as the `--headless` scout option" → shipped
  wording, mirroring `docs/claude.md:33,73`. (Risk: LOW.)
- [x] `AGENTS.md` (Dispatch section) — one line naming `--headless` and its
  "cannot be steered mid-flight" trade-off. (Risk: LOW.)

### Deferred, gated on human sign-off (MED risk — do NOT do under this plan)

1. **[MED] `bin/cs-watch.sh:1122-1287` — headless-aware non-terminal stale.**
   Stop surfacing a mid-run headless scout's pane as "went quiet." Either
   (a) read `headless` from meta and treat a headless scout's non-terminal idle
   pane as provably-working while its process/agent is alive, or (b) teach
   `cs-crew-state.sh` to report a live headless exec as `working` (`source:
   pane`) so the existing `crew_is_provably_working` absorb already applies.
   *Risk:* touches supervision/absorb semantics; must not suppress a genuinely
   wedged or finished headless scout. Note the terminal `done:`/`failed:` wake
   still fires via the signal path independent of this change, so completion
   reporting is not at stake — only mid-run noise suppression.
2. **[LOW-MED] `bin/cs-crew-state.sh` (:42 scout fallback, :579 pane path) —
   optional headless awareness** so the fleet-view current-state column reads
   sensibly during a run (`working` vs `parked`). *Risk:* low; read-only
   current-state reconciliation. Largely subsumed by option 1(b).

Explicitly **not** required for finish: completion detection (works), teardown
(works via the `kind=scout` carve-out), meta plumbing (works), spawn (works).

## The alternative (REMOVE), for completeness

Not recommended. If chosen, it is a user-facing capability removal and needs boss
sign-off before any code is touched. It would remove `--headless` from
`bin/cs-spawn.sh` (flag `:94`, guard `:121-123`, meta `:238`, launch branch
`:246-252`, echo note `:271-272`), `cs_harness_scout_launch` from
`bin/cs-harness-lib.sh:245-262`, the `headless=1` documentation
(`docs/codex.md`, `docs/claude.md:33,73`, `docs/configuration.md:38`), and the
fleet-view labeling added here. Given completion detection already works, this
throws away a working capability for no supervision-safety gain.
