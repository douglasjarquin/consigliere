#!/usr/bin/env bash
# Behavior (portable): cs-spawn.sh's spawn_codegraph_prep builds the project's
# codegraph index into every new task worktree, and re-runs it on relaunch,
# but never at the cost of the spawn itself.
#
# Every negative direction is fail-open: no codegraph binary, no built index
# in the primary, an unclean committed-ignore guard, an exhausted time
# bound, or the CS_SPAWN_CODEGRAPH_PREP=off kill switch must all let the
# spawn proceed, with output limited to at most one stderr line. Only the
# positive case invokes codegraph at all, and only ever positionally against
# the worktree root - never the primary checkout.
set -u
# shellcheck source=tests/control-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/control-helpers.sh"

SPAWN="$ROOT/bin/cs-spawn.sh"
TMP=$(cs_test_tmproot cs-spawn-idxprep)
FAKEBIN=$(cs_fakebin "$TMP")
cs_git_identity
export CS_SPAWN_LAUNCH_WAIT_SECS=5 CS_CONTROL_RESUME_WAIT_SECS=3 CS_CONTROL_RESUME_GRACE_SECS=1

# make_fake_herdr <dir> - the base-freshness-style fake: real `git worktree
# add` behind "worktree create", an agent that is always immediately present,
# and "pane run" recording the delivered launch line. Sufficient for a plain
# ship spawn; relaunch needs the richer FAKE_STATE-driven fake below instead.
make_fake_herdr() {
  cat > "$1/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "status --json") printf '%s\n' '{"server":{"protocol":16}}' ;;
  "worktree create")
    repo= branch= base=
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --cwd) repo=$2; shift ;;
        --branch) branch=$2; shift ;;
        --base) base=$2; shift ;;
      esac
      shift
    done
    if [ -n "$base" ]; then
      git -C "$repo" worktree add -q -b "$branch" "$CS_FAKE_SPAWN_WORKTREE" "$base"
    else
      git -C "$repo" worktree add -q -b "$branch" "$CS_FAKE_SPAWN_WORKTREE"
    fi
    case "${CS_FAKE_SPAWN_SEED_INDEX:-}" in
      '') ;;
      lock)
        mkdir -p "$CS_FAKE_SPAWN_WORKTREE/.codegraph"
        printf 'interrupted\n' > "$CS_FAKE_SPAWN_WORKTREE/.codegraph/codegraph.lock"
        ;;
      *)
        mkdir -p "$CS_FAKE_SPAWN_WORKTREE/.codegraph"
        printf 'seeded-db\n' > "$CS_FAKE_SPAWN_WORKTREE/.codegraph/codegraph.db"
        ;;
    esac
    printf '{"result":{"workspace":{"workspace_id":"w1"},"root_pane":{"pane_id":"w1:p1"},"worktree":{"path":"%s","branch":"%s"}}}\n' "$CS_FAKE_SPAWN_WORKTREE" "$branch"
    ;;
  "pane run") printf '%s' "${4:-}" > "$CS_FAKE_SPAWN_LAUNCH" ;;
  "agent get") printf '{"result":{"agent":{"agent":"codex","agent_status":"idle"}}}\n' ;;
  *) printf '{}\n' ;;
esac
SH
  chmod +x "$1/herdr"
}

# make_fake_codegraph <dir> - records every invocation's argv to
# CS_FAKE_CODEGRAPH_LOG, then optionally sleeps (CS_FAKE_CODEGRAPH_SLEEP, for
# the timeout case) before exiting CS_FAKE_CODEGRAPH_EXIT (default 0). It
# models real init's on-disk staging too: a lock file inside the target's
# .codegraph the whole time it works, replaced by codegraph.db only when it
# gets to exit 0 - so an interrupted or failed run leaves the same unusable
# half-written index behind that codegraph itself does.
# CS_FAKE_CODEGRAPH_WEDGE makes that leftover unremovable (a child under a
# write-denied directory, the portable stand-in for a detached codegraph
# worker still writing while the cleanup walks the tree), so the cleanup's own
# failure is exercised rather than assumed.
# It also short-circuits on an existing .codegraph the way real init does -
# "Already initialized", exit 0, nothing rebuilt - which is what makes a
# leftover from an earlier run dangerous rather than self-healing.
make_fake_codegraph() {
  cat > "$1/codegraph" <<'SH'
#!/usr/bin/env bash
set -u
log=${CS_FAKE_CODEGRAPH_LOG:-/dev/null}
{
  printf 'argv:'
  for a in "$@"; do printf ' %s' "$a"; done
  printf '\n'
} >> "$log"
target=
[ "${1:-}" = init ] && target=${2:-}
rc=${CS_FAKE_CODEGRAPH_EXIT:-0}
if [ -n "$target" ] && [ "$rc" = 0 ] && [ -e "$target/.codegraph" ]; then
  printf 'Already initialized\n'
  exit 0
fi
if [ -n "$target" ]; then
  mkdir -p "$target/.codegraph"
  printf 'indexing\n' > "$target/.codegraph/codegraph.lock"
  if [ -n "${CS_FAKE_CODEGRAPH_WEDGE:-}" ]; then
    mkdir -p "$target/.codegraph/wedged"
    printf 'held\n' > "$target/.codegraph/wedged/held"
    chmod 500 "$target/.codegraph/wedged"
  fi
fi
[ -n "${CS_FAKE_CODEGRAPH_SLEEP:-}" ] && sleep "$CS_FAKE_CODEGRAPH_SLEEP"
if [ "$rc" = 0 ] && [ -n "$target" ]; then
  rm -f "$target/.codegraph/codegraph.lock"
  printf 'built-db\n' > "$target/.codegraph/codegraph.db"
fi
exit "$rc"
SH
  chmod +x "$1/codegraph"
}

make_fake_herdr "$FAKEBIN"
make_fake_codegraph "$FAKEBIN"

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state"

# codegraph_repo <name> <ignore:yes|dir|no> <indexed:yes|no> - a fresh
# one-commit repo, echoing its path. `ignore=yes` commits the bare
# `.codegraph` gitignore rule and `ignore=dir` the directory-only
# `.codegraph/` form - both are rules a real project carries, and git treats
# them differently against a path that does not exist yet. `indexed=yes`
# leaves .codegraph/codegraph.db UNTRACKED in the working tree, exactly how a
# real primary's local index sits on disk.
codegraph_repo() {
  local dir="$TMP/proj-$1" ignore=$2 indexed=$3 rule=
  cs_git_init_commit "$dir"
  case "$ignore" in
    yes) rule='.codegraph' ;;
    dir) rule='.codegraph/' ;;
  esac
  if [ -n "$rule" ]; then
    printf '%s\n' "$rule" > "$dir/.gitignore"
    git -C "$dir" add .gitignore
    git -C "$dir" -c user.name='Consigliere Tests' -c user.email='tests@example.invalid' \
      commit -qm "ignore $rule"
  fi
  if [ "$indexed" = yes ]; then
    mkdir -p "$dir/.codegraph"
    printf 'fixture-db\n' > "$dir/.codegraph/codegraph.db"
  fi
  printf '%s\n' "$dir"
}

# path_sans_codegraph - $PATH with the directory holding the REAL codegraph
# binary REPLACED by a shadow directory holding a symlink to every OTHER tool
# that directory carries, so a case testing "no codegraph on PATH" is not
# answered by whatever this dev machine or CI runner happens to have
# installed, without also hiding an unrelated tool (e.g. a homebrew python3
# that ships tomllib, which cs_harness_codex_trust_dir needs) that happens to
# live alongside it.
CODEGRAPH_REAL_DIR=""
CODEGRAPH_SHADOW_DIR="$TMP/codegraph-dir-shadow"
if p=$(command -v codegraph 2>/dev/null); then
  CODEGRAPH_REAL_DIR=$(cd "$(dirname "$p")" && pwd -P)
  mkdir -p "$CODEGRAPH_SHADOW_DIR"
  for f in "$CODEGRAPH_REAL_DIR"/*; do
    [ "$(basename "$f")" = codegraph ] && continue
    ln -s "$f" "$CODEGRAPH_SHADOW_DIR/$(basename "$f")"
  done
fi
path_sans_codegraph() {
  local part rp out=
  local IFS=:
  for part in $PATH; do
    if [ -n "$CODEGRAPH_REAL_DIR" ]; then
      rp=$(cd "$part" 2>/dev/null && pwd -P) || rp=$part
      if [ "$rp" = "$CODEGRAPH_REAL_DIR" ]; then
        out="${out:+$out:}$CODEGRAPH_SHADOW_DIR"
        continue
      fi
    fi
    out="${out:+$out:}$part"
  done
  printf '%s\n' "$out"
}

# spawn_case <id> <repo> <codegraph-log> <path> [K=V ...] - a ship spawn
# against the fake herdr above, echoing combined output. Never fails the
# test itself: several cases assert on a spawn that must still succeed while
# warning.
spawn_case() {
  local id=$1 repo=$2 log=$3 path=$4
  shift 4
  mkdir -p "$HOME_DIR/data/$id"
  printf 'implement the fixture\nDelivery contract: mode=made\n' > "$HOME_DIR/data/$id/brief.md"
  env PATH="$path" CS_HARNESS_OVERRIDE=codex \
    CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$HOME_DIR/state" \
    CS_FAKE_SPAWN_WORKTREE="$TMP/wt-$id" CS_FAKE_SPAWN_LAUNCH="$TMP/launch-$id" \
    CS_FAKE_CODEGRAPH_LOG="$log" \
    "$@" \
    "$SPAWN" "$id" "$repo" --mode made --yolo off 2>&1
}

# --- 1. prep fires, positional-only ------------------------------------------

REPO1=$(codegraph_repo case1 yes yes)
LOG1="$TMP/codegraph-case1.log"
out=$(spawn_case t-case1 "$REPO1" "$LOG1" "$FAKEBIN:$PATH") ||
  fail "a spawn with a built codegraph index in the primary must succeed: $out"
WT1_REAL=$(cd "$TMP/wt-t-case1" && pwd -P)
assert_present "$LOG1" "codegraph must have been invoked when the primary carries a built index"
log1=$(cat "$LOG1")
assert_line "$log1" "^argv: init $WT1_REAL\$" "codegraph init must run positionally against the worktree root, nothing else"
[ -f "$WT1_REAL/.codegraph/codegraph.db" ] ||
  fail "a successful prep must leave the built index in the worktree"
pass "cs-spawn codegraph prep: fires positionally against the worktree root"

# --- 8. build-target assertion: the primary is never the build target -------

PROJ1_REAL=$(cd "$REPO1" && pwd -P)
[ "$WT1_REAL" != "$PROJ1_REAL" ] || fail "fixture bug: the worktree and the primary must not be the same path"
assert_not_contains "$log1" "$PROJ1_REAL" "codegraph init must never be invoked against the primary checkout's path"
pass "cs-spawn codegraph prep: the primary checkout is never the build target, only the worktree"

# --- 2. no codegraph binary on PATH: silent no-op ----------------------------

REPO2=$(codegraph_repo case2 yes yes)
LOG2="$TMP/codegraph-case2.log"
NOCG_FAKEBIN="$TMP/fakebin-nocodegraph"
mkdir -p "$NOCG_FAKEBIN"
make_fake_herdr "$NOCG_FAKEBIN"
out=$(spawn_case t-case2 "$REPO2" "$LOG2" "$NOCG_FAKEBIN:$(path_sans_codegraph)") ||
  fail "a spawn on a machine with no codegraph binary must still succeed: $out"
assert_absent "$LOG2" "codegraph must never be invoked when the binary is not on PATH"
assert_not_contains "$out" 'codegraph init' "a missing codegraph binary must produce zero prep output"
pass "cs-spawn codegraph prep: no codegraph binary on PATH is a silent no-op"

# --- 3. no codegraph.db in the primary: silent no-op -------------------------

REPO3=$(codegraph_repo case3 yes no)
LOG3="$TMP/codegraph-case3.log"
out=$(spawn_case t-case3 "$REPO3" "$LOG3" "$FAKEBIN:$PATH") ||
  fail "a spawn against a project with no built codegraph index must still succeed: $out"
assert_absent "$LOG3" "codegraph must never be invoked when the primary has no .codegraph/codegraph.db"
assert_not_contains "$out" 'codegraph init' "a primary with no built index must produce zero prep output"
pass "cs-spawn codegraph prep: no codegraph.db in the primary is a silent no-op"

# --- 4. the committed-ignore guard failing: one warning, no invocation ------

REPO4=$(codegraph_repo case4 no yes)
LOG4="$TMP/codegraph-case4.log"
out=$(spawn_case t-case4 "$REPO4" "$LOG4" "$FAKEBIN:$PATH") ||
  fail "a spawn against a project whose committed rules do not ignore .codegraph must still succeed: $out"
assert_absent "$LOG4" "codegraph must never be invoked while the cleanliness guard fails"
assert_contains "$out" "do not ignore .codegraph" "the guard failure must be reported, not silent"
pass "cs-spawn codegraph prep: an unclean committed-ignore guard warns and skips, never invokes codegraph"

# --- 10. the directory-only ignore rule satisfies the guard too --------------

REPO10=$(codegraph_repo case10 dir yes)
LOG10="$TMP/codegraph-case10.log"
out=$(spawn_case t-case10 "$REPO10" "$LOG10" "$FAKEBIN:$PATH") ||
  fail "a spawn against a project whose committed rule is the directory-only .codegraph/ must succeed: $out"
WT10_REAL=$(cd "$TMP/wt-t-case10" && pwd -P)
assert_present "$LOG10" "a committed .codegraph/ rule must satisfy the guard, not skip the prep"
assert_line "$(cat "$LOG10")" "^argv: init $WT10_REAL\$" "the prep must still run positionally against the worktree root"
assert_not_contains "$out" "do not ignore .codegraph" "a project that does ignore .codegraph must never be told it does not"
pass "cs-spawn codegraph prep: a directory-only .codegraph/ committed rule satisfies the guard"

# --- 5. a timeout is fail-open, loudly ---------------------------------------

REPO5=$(codegraph_repo case5 yes yes)
LOG5="$TMP/codegraph-case5.log"
out=$(spawn_case t-case5 "$REPO5" "$LOG5" "$FAKEBIN:$PATH" \
  CS_SPAWN_CODEGRAPH_TIMEOUT_SECS=1 CS_FAKE_CODEGRAPH_SLEEP=3) ||
  fail "a codegraph init that outlives its bound must still let the spawn succeed: $out"
assert_contains "$out" "did not finish within 1s" "an expired bound must be reported loudly"
assert_present "$HOME_DIR/state/t-case5.meta" "the spawn must still complete after the timeout"
WT5_REAL=$(cd "$TMP/wt-t-case5" && pwd -P)
[ -e "$WT5_REAL/.codegraph" ] &&
  fail "a killed codegraph init must leave no half-written index behind, found $(ls -A "$WT5_REAL/.codegraph" | tr '\n' ' ')"
pass "cs-spawn codegraph prep: a codegraph init that outlives its bound is fail-open and loud"

# --- 11. a cleanup that cannot finish never takes the spawn down ------------

if [ "$(id -u)" = 0 ]; then
  pass "cs-spawn codegraph prep: unremovable-leftover check skipped: running as root, where the mode bits do not apply"
else
  REPO11=$(codegraph_repo case11 yes yes)
  LOG11="$TMP/codegraph-case11.log"
  out=$(spawn_case t-case11 "$REPO11" "$LOG11" "$FAKEBIN:$PATH" \
    CS_FAKE_CODEGRAPH_EXIT=3 CS_FAKE_CODEGRAPH_WEDGE=1)
  rc11=$?
  WT11_REAL=$(cd "$TMP/wt-t-case11" 2>/dev/null && pwd -P) || WT11_REAL="$TMP/wt-t-case11"
  chmod 700 "$WT11_REAL/.codegraph/wedged" 2>/dev/null || true
  [ "$rc11" = 0 ] ||
    fail "a spawn whose half-written index cannot be removed must still succeed: $out"
  assert_present "$HOME_DIR/state/t-case11.meta" "the spawn must complete even when the cleanup cannot"
  assert_present "$TMP/launch-t-case11" "the launch line must still be delivered to the task pane"
  [ -e "$WT11_REAL/.codegraph" ] ||
    fail "fixture bug: this case only means anything while the leftover survives the cleanup"
  assert_contains "$out" "could not be removed" \
    "a leftover the cleanup could not take must be named, not reported as a clean worktree"
  pass "cs-spawn codegraph prep: a cleanup that cannot finish is reported, never fatal"
fi

# --- 12. an interrupted index from an earlier run is rebuilt, not adopted ----

REPO12=$(codegraph_repo case12 yes yes)
LOG12="$TMP/codegraph-case12.log"
out=$(spawn_case t-case12 "$REPO12" "$LOG12" "$FAKEBIN:$PATH" CS_FAKE_SPAWN_SEED_INDEX=lock) ||
  fail "a spawn over a worktree carrying an interrupted index must succeed: $out"
WT12_REAL=$(cd "$TMP/wt-t-case12" && pwd -P)
[ -f "$WT12_REAL/.codegraph/codegraph.db" ] ||
  fail "a lock-only leftover must be rebuilt into a real index, not adopted as one"
[ -e "$WT12_REAL/.codegraph/codegraph.lock" ] &&
  fail "the interrupted run's lock must not survive the rebuild"
assert_contains "$out" "built codegraph index" "the rebuild must be reported as the build it actually was"
pass "cs-spawn codegraph prep: an interrupted index from an earlier run is rebuilt, never adopted"

# --- 9. a failed prep never destroys an index the worktree already had ------

REPO9=$(codegraph_repo case9 yes yes)
LOG9="$TMP/codegraph-case9.log"
out=$(spawn_case t-case9 "$REPO9" "$LOG9" "$FAKEBIN:$PATH" \
  CS_FAKE_SPAWN_SEED_INDEX=1 CS_FAKE_CODEGRAPH_EXIT=3) ||
  fail "a spawn whose codegraph init fails must still succeed: $out"
WT9_REAL=$(cd "$TMP/wt-t-case9" && pwd -P)
[ -f "$WT9_REAL/.codegraph/codegraph.db" ] ||
  fail "a failed prep must never delete an index the worktree already carried"
assert_contains "$out" "keeps the codegraph index it already had" \
  "a failed prep over an existing index must not claim the worktree has none"
pass "cs-spawn codegraph prep: a failed prep leaves a pre-existing worktree index intact"

# --- 6. CS_SPAWN_CODEGRAPH_PREP=off: the kill switch is total ---------------

REPO6=$(codegraph_repo case6 yes yes)
LOG6="$TMP/codegraph-case6.log"
out=$(spawn_case t-case6 "$REPO6" "$LOG6" "$FAKEBIN:$PATH" CS_SPAWN_CODEGRAPH_PREP=off) ||
  fail "a spawn with the kill switch on must still succeed: $out"
assert_absent "$LOG6" "codegraph must never be invoked while CS_SPAWN_CODEGRAPH_PREP=off"
assert_not_contains "$out" 'codegraph init' "the kill switch must produce zero prep output"
pass "cs-spawn codegraph prep: CS_SPAWN_CODEGRAPH_PREP=off disables prep entirely, with no output"

# --- 7. relaunch re-runs the same idempotent prep call -----------------------

REPO7=$(codegraph_repo case7 yes yes)
LOG7="$TMP/codegraph-case7.log"
FAKEBIN7="$TMP/fakebin-case7"
mkdir -p "$FAKEBIN7"
make_fake_herdr "$FAKEBIN7"
make_fake_codegraph "$FAKEBIN7"
out=$(spawn_case t-case7 "$REPO7" "$LOG7" "$FAKEBIN7:$PATH") ||
  fail "the initial spawn of the relaunch fixture must succeed: $out"
WT7_REAL=$(cd "$TMP/wt-t-case7" && pwd -P)
assert_present "$LOG7" "the initial spawn leg must have invoked codegraph once"
[ "$(grep -c '^argv:' "$LOG7")" = 1 ] || fail "the spawn leg must invoke codegraph exactly once"

# Swap in the FAKE_STATE-driven herdr (tests/control-helpers.sh) for the
# relaunch leg: cs-spawn.sh --relaunch checks pane presence, positive
# agent-freedom, and cwd through herdr calls this fixture's plain "worktree
# create" fake does not answer. `agent=` (empty) models a pane whose harness
# already exited on its own - a legitimate state to relaunch from - and
# `on_run=up` brings a fresh agent up on the resume attempt, matching the
# happy path tests/cs-control-relaunch.test.sh already proves against the
# same fake.
cs_control_fake_herdr "$FAKEBIN7"
RSTATE=$(cs_control_state "$TMP/relaunch-state-case7" agent= cwd="$WT7_REAL" on_run=up)
env PATH="$FAKEBIN7:$PATH" CS_HARNESS_OVERRIDE=codex \
  CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$HOME_DIR/state" \
  CS_FAKE_CODEGRAPH_LOG="$LOG7" FAKE_STATE="$RSTATE" \
  "$SPAWN" --relaunch t-case7 > "$TMP/relaunch-case7.out" 2>&1 ||
  fail "the relaunch leg must succeed: $(cat "$TMP/relaunch-case7.out")"
[ "$(grep -c '^argv:' "$LOG7")" = 2 ] ||
  fail "relaunch must re-run codegraph prep, giving two invocations total across spawn+relaunch, got $(grep -c '^argv:' "$LOG7")"
pass "cs-spawn codegraph prep: a relaunch re-runs the same idempotent prep call"
