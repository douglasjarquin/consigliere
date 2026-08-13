#!/usr/bin/env bash
# Behavior (portable): cs-spawn.sh's spawn_graft_prep builds the project's
# graft index into every new task worktree, and re-runs it on relaunch, but
# never at the cost of the spawn itself.
#
# Every negative direction is fail-open: no graft binary, no built index in
# the primary, an unclean committed-ignore guard, an exhausted time bound, or
# the CS_SPAWN_GRAFT_PREP=off kill switch must all let the spawn proceed, with
# output limited to at most one stderr line. Only the positive case invokes
# graft at all, and only ever positionally against the worktree root - never
# `--dir` (which disables graft's own seeding), never `--deep`, and never the
# primary checkout.
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
    printf '{"result":{"workspace":{"workspace_id":"w1"},"root_pane":{"pane_id":"w1:p1"},"worktree":{"path":"%s","branch":"%s"}}}\n' "$CS_FAKE_SPAWN_WORKTREE" "$branch"
    ;;
  "pane run") printf '%s' "${4:-}" > "$CS_FAKE_SPAWN_LAUNCH" ;;
  "agent get") printf '{"result":{"agent":{"agent":"codex","agent_status":"idle"}}}\n' ;;
  *) printf '{}\n' ;;
esac
SH
  chmod +x "$1/herdr"
}

# make_fake_graft <dir> - records every invocation's argv and the value it saw
# for GRAFT_API_KEY (so a test can prove the prep step stripped it) to
# CS_FAKE_GRAFT_LOG, then optionally sleeps (CS_FAKE_GRAFT_SLEEP, for the
# timeout case) before exiting CS_FAKE_GRAFT_EXIT (default 0).
make_fake_graft() {
  cat > "$1/graft" <<'SH'
#!/usr/bin/env bash
set -u
log=${CS_FAKE_GRAFT_LOG:-/dev/null}
{
  printf 'argv: build'
  shift 1 2>/dev/null || true
  for a in "$@"; do printf ' %s' "$a"; done
  printf '\n'
  printf 'GRAFT_API_KEY=%s\n' "${GRAFT_API_KEY-<unset>}"
} >> "$log"
[ -n "${CS_FAKE_GRAFT_SLEEP:-}" ] && sleep "$CS_FAKE_GRAFT_SLEEP"
exit "${CS_FAKE_GRAFT_EXIT:-0}"
SH
  chmod +x "$1/graft"
}

make_fake_herdr "$FAKEBIN"
make_fake_graft "$FAKEBIN"

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state"

# graft_repo <name> <ignore:yes|no> <wiring:yes|no> - a fresh one-commit repo,
# echoing its path. `ignore=yes` commits a graft/ gitignore rule (what a
# project that has ever run `graft build` at its root carries); `wiring=yes`
# leaves graft/.graph/wiring.json UNTRACKED in the working tree, exactly how a
# real primary's local index sits on disk.
graft_repo() {
  local dir="$TMP/proj-$1" ignore=$2 wiring=$3
  cs_git_init_commit "$dir"
  if [ "$ignore" = yes ]; then
    printf 'graft/\n' > "$dir/.gitignore"
    git -C "$dir" add .gitignore
    git -C "$dir" -c user.name='Consigliere Tests' -c user.email='tests@example.invalid' \
      commit -qm 'ignore graft/'
  fi
  if [ "$wiring" = yes ]; then
    mkdir -p "$dir/graft/.graph"
    printf '{}\n' > "$dir/graft/.graph/wiring.json"
  fi
  printf '%s\n' "$dir"
}

# path_sans_graft - $PATH with the directory holding the REAL graft binary
# REPLACED by a shadow directory holding a symlink to every OTHER tool that
# directory carries, so a case testing "no graft on PATH" is not answered by
# whatever this dev machine or CI runner happens to have installed, without
# also hiding an unrelated tool (e.g. a homebrew python3 that ships tomllib,
# which cs_harness_codex_trust_dir needs) that happens to live alongside it.
GRAFT_REAL_DIR=""
GRAFT_SHADOW_DIR="$TMP/graft-dir-shadow"
if p=$(command -v graft 2>/dev/null); then
  GRAFT_REAL_DIR=$(cd "$(dirname "$p")" && pwd -P)
  mkdir -p "$GRAFT_SHADOW_DIR"
  for f in "$GRAFT_REAL_DIR"/*; do
    [ "$(basename "$f")" = graft ] && continue
    ln -s "$f" "$GRAFT_SHADOW_DIR/$(basename "$f")"
  done
fi
path_sans_graft() {
  local part rp out=
  local IFS=:
  for part in $PATH; do
    if [ -n "$GRAFT_REAL_DIR" ]; then
      rp=$(cd "$part" 2>/dev/null && pwd -P) || rp=$part
      if [ "$rp" = "$GRAFT_REAL_DIR" ]; then
        out="${out:+$out:}$GRAFT_SHADOW_DIR"
        continue
      fi
    fi
    out="${out:+$out:}$part"
  done
  printf '%s\n' "$out"
}

# spawn_case <id> <repo> <graft-log> <path> [K=V ...] - a ship spawn against
# the fake herdr above, echoing combined output. Never fails the test itself:
# several cases assert on a spawn that must still succeed while warning.
spawn_case() {
  local id=$1 repo=$2 log=$3 path=$4
  shift 4
  mkdir -p "$HOME_DIR/data/$id"
  printf 'implement the fixture\nDelivery contract: mode=no-mistakes\n' > "$HOME_DIR/data/$id/brief.md"
  env PATH="$path" CS_HARNESS_OVERRIDE=codex \
    CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$HOME_DIR/state" \
    CS_FAKE_SPAWN_WORKTREE="$TMP/wt-$id" CS_FAKE_SPAWN_LAUNCH="$TMP/launch-$id" \
    CS_FAKE_GRAFT_LOG="$log" \
    "$@" \
    "$SPAWN" "$id" "$repo" --mode no-mistakes --yolo off 2>&1
}

EVIDENCE="$ROOT/.no-mistakes/evidence"
mkdir -p "$EVIDENCE"

# --- 1. prep fires, positional-only, GRAFT_API_KEY stripped ------------------

REPO1=$(graft_repo case1 yes yes)
LOG1="$TMP/graft-case1.log"
out=$(spawn_case t-case1 "$REPO1" "$LOG1" "$FAKEBIN:$PATH" GRAFT_API_KEY=poison-token) ||
  fail "a spawn with a built graft index in the primary must succeed: $out"
WT1_REAL=$(cd "$TMP/wt-t-case1" && pwd -P)
assert_present "$LOG1" "graft must have been invoked when the primary carries a built index"
log1=$(cat "$LOG1")
assert_line "$log1" "^argv: build $WT1_REAL\$" "graft build must run positionally against the worktree root, nothing else"
assert_not_contains "$log1" -- '--dir' "graft build must never be called with --dir (it disables graft's own seeding)"
assert_not_contains "$log1" -- '--deep' "graft build must never be called with --deep"
assert_contains "$log1" 'GRAFT_API_KEY=<unset>' "the prep environment must strip GRAFT_API_KEY even when the parent shell carried one"
{
  printf '=== Scenario: Prep fires and is positional-only ===\n\n'
  printf 'spawn output:\n%s\n\n' "$out"
  printf 'fake-graft argv log (%s):\n%s\n' "$LOG1" "$log1"
} > "$EVIDENCE/task-1-prep-argv.txt"
pass "cs-spawn graft prep: fires positionally against the worktree root with GRAFT_API_KEY stripped"

# --- 8. build-target assertion: the primary is never the build target -------

PROJ1_REAL=$(cd "$REPO1" && pwd -P)
[ "$WT1_REAL" != "$PROJ1_REAL" ] || fail "fixture bug: the worktree and the primary must not be the same path"
assert_not_contains "$log1" "$PROJ1_REAL" "graft build must never be invoked against the primary checkout's path"
pass "cs-spawn graft prep: the primary checkout is never the build target, only the worktree"

# --- 2. no graft binary on PATH: silent no-op --------------------------------

REPO2=$(graft_repo case2 yes yes)
LOG2="$TMP/graft-case2.log"
NOGRAFT_FAKEBIN="$TMP/fakebin-nograft"
mkdir -p "$NOGRAFT_FAKEBIN"
make_fake_herdr "$NOGRAFT_FAKEBIN"
out=$(spawn_case t-case2 "$REPO2" "$LOG2" "$NOGRAFT_FAKEBIN:$(path_sans_graft)") ||
  fail "a spawn on a machine with no graft binary must still succeed: $out"
assert_absent "$LOG2" "graft must never be invoked when the binary is not on PATH"
assert_not_contains "$out" graft "a missing graft binary must produce zero prep output"
pass "cs-spawn graft prep: no graft binary on PATH is a silent no-op"

# --- 3. no wiring.json in the primary: silent no-op --------------------------

REPO3=$(graft_repo case3 yes no)
LOG3="$TMP/graft-case3.log"
out=$(spawn_case t-case3 "$REPO3" "$LOG3" "$FAKEBIN:$PATH") ||
  fail "a spawn against a project with no built graft index must still succeed: $out"
assert_absent "$LOG3" "graft must never be invoked when the primary has no graft/.graph/wiring.json"
assert_not_contains "$out" graft "a primary with no built index must produce zero prep output"
pass "cs-spawn graft prep: no wiring.json in the primary is a silent no-op"

# --- 4. the committed-ignore guard failing: one warning, no invocation ------

REPO4=$(graft_repo case4 no yes)
LOG4="$TMP/graft-case4.log"
out=$(spawn_case t-case4 "$REPO4" "$LOG4" "$FAKEBIN:$PATH") ||
  fail "a spawn against a project whose committed rules do not ignore graft/ must still succeed: $out"
assert_absent "$LOG4" "graft must never be invoked while the cleanliness guard fails"
assert_contains "$out" "do not ignore graft/" "the guard failure must be reported, not silent"
pass "cs-spawn graft prep: an unclean committed-ignore guard warns and skips, never invokes graft"

# --- 5. a timeout is fail-open, loudly ---------------------------------------

REPO5=$(graft_repo case5 yes yes)
LOG5="$TMP/graft-case5.log"
out=$(spawn_case t-case5 "$REPO5" "$LOG5" "$FAKEBIN:$PATH" \
  CS_SPAWN_GRAFT_TIMEOUT_SECS=1 CS_FAKE_GRAFT_SLEEP=3) ||
  fail "a graft build that outlives its bound must still let the spawn succeed: $out"
assert_contains "$out" "did not finish within 1s" "an expired bound must be reported loudly"
assert_present "$HOME_DIR/state/t-case5.meta" "the spawn must still complete after the timeout"
pass "cs-spawn graft prep: a graft build that outlives its bound is fail-open and loud"

# --- 6. CS_SPAWN_GRAFT_PREP=off: the kill switch is total -------------------

REPO6=$(graft_repo case6 yes yes)
LOG6="$TMP/graft-case6.log"
out=$(spawn_case t-case6 "$REPO6" "$LOG6" "$FAKEBIN:$PATH" CS_SPAWN_GRAFT_PREP=off) ||
  fail "a spawn with the kill switch on must still succeed: $out"
assert_absent "$LOG6" "graft must never be invoked while CS_SPAWN_GRAFT_PREP=off"
assert_not_contains "$out" graft "the kill switch must produce zero prep output"
pass "cs-spawn graft prep: CS_SPAWN_GRAFT_PREP=off disables prep entirely, with no output"

# --- 7. relaunch re-runs the same idempotent prep call -----------------------

REPO7=$(graft_repo case7 yes yes)
LOG7="$TMP/graft-case7.log"
FAKEBIN7="$TMP/fakebin-case7"
mkdir -p "$FAKEBIN7"
make_fake_herdr "$FAKEBIN7"
make_fake_graft "$FAKEBIN7"
out=$(spawn_case t-case7 "$REPO7" "$LOG7" "$FAKEBIN7:$PATH") ||
  fail "the initial spawn of the relaunch fixture must succeed: $out"
WT7_REAL=$(cd "$TMP/wt-t-case7" && pwd -P)
assert_present "$LOG7" "the initial spawn leg must have invoked graft once"
[ "$(grep -c '^argv:' "$LOG7")" = 1 ] || fail "the spawn leg must invoke graft exactly once"

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
  CS_FAKE_GRAFT_LOG="$LOG7" FAKE_STATE="$RSTATE" \
  "$SPAWN" --relaunch t-case7 > "$TMP/relaunch-case7.out" 2>&1 ||
  fail "the relaunch leg must succeed: $(cat "$TMP/relaunch-case7.out")"
[ "$(grep -c '^argv:' "$LOG7")" = 2 ] ||
  fail "relaunch must re-run graft prep, giving two invocations total across spawn+relaunch, got $(grep -c '^argv:' "$LOG7")"
{
  printf '=== Scenario: relaunch re-runs the same idempotent prep call ===\n\n'
  printf 'spawn leg output:\n%s\n\n' "$out"
  printf 'relaunch leg output:\n%s\n\n' "$(cat "$TMP/relaunch-case7.out")"
  printf 'fake-graft argv log (%s), %s invocation(s):\n%s\n' "$LOG7" "$(grep -c '^argv:' "$LOG7")" "$(cat "$LOG7")"
} > "$EVIDENCE/task-1-fail-open.txt"
pass "cs-spawn graft prep: a relaunch re-runs the same idempotent prep call"

{
  printf '=== Scenario: Suite proves the fail-open contract ===\n\n'
  printf 'bin/cs-test-run.sh tests/cs-spawn-graft.test.sh\n'
} > "$EVIDENCE/task-3-suite.txt"
