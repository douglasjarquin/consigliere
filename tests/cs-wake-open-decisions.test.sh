#!/usr/bin/env bash
# tests/cs-wake-open-decisions.test.sh - the fleet-wide OPEN DECISIONS section
# that cs-wake-drain.sh prints on every drain. A needs-decision/needs-review/
# blocked line buried under later unrelated status appends is only visible
# through the last-line wake annotation, so a still-open decision could go
# silently missed. These cases prove the section surfaces every still-open keyed
# decision (empty-queue fast path AND non-empty drain), never a resolved one,
# skips an unreadable or symlinked status file without stderr noise, stays quiet
# on a clean drain, and leaves the existing raw-row/annotation behavior intact.
# They also exercise the classify-lib fold wrapper (scan_open_decisions) and the
# directory-wide file-handling guards on status_open_decisions directly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRAIN="$ROOT/bin/cs-wake-drain.sh"
CLASSIFY="$ROOT/bin/cs-classify-lib.sh"

TMP_ROOT=$(cs_test_tmproot cs-wake-open-decisions)

# cs-wake-drain.sh calls cs-guard.sh on every drain; point its worktree-tangle
# check at a fresh non-git dir so a feature-branch test checkout does not emit a
# spurious banner (mirrors cs-wake-queue.test.sh).
CS_ROOT_OVERRIDE="$TMP_ROOT/tangle-root"
mkdir -p "$CS_ROOT_OVERRIDE"
export CS_ROOT_OVERRIDE

make_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  printf '%s\n' "$dir"
}

# run_drain <state> <stdout-file> <stderr-file>: drain scoped to <state>.
run_drain() {
  local state=$1 out=$2 err=$3
  CS_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err"
}

# append_wake <state> <kind> <key> <payload>: enqueue via the production library.
append_wake() {
  local state=$1 kind=$2 key=$3 payload=$4
  CS_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"; cs_wake_append "$2" "$3" "$4"
  ' _ "$ROOT/bin/cs-wake-lib.sh" "$kind" "$key" "$payload"
}

# scan_wrapper <state>: the fleet-wide fold wrapper, run in a clean subshell.
scan_wrapper() {
  bash -c '. "$1"; scan_open_decisions "$2"' _ "$CLASSIFY" "$1"
}

# fold_one <status-file>: the single-file fold, run in a clean subshell.
fold_one() {
  bash -c '. "$1"; status_open_decisions "$2"' _ "$CLASSIFY" "$1"
}

test_buried_decision_surfaces_on_empty_drain() {
  local dir state out err
  dir=$(make_case buried-empty); state="$dir/state"
  out="$dir/out"; err="$dir/err"
  # A still-open decision pushed off the last line by later unrelated appends.
  printf 'working: start\nneeds-decision [key=api]: pick A or B\nworking: more\ndone: unrelated finish\n' \
    > "$state/t1.status"
  run_drain "$state" "$out" "$err" || fail "empty-queue drain failed"
  assert_grep "OPEN DECISIONS" "$out" "empty-queue drain must print the section header"
  assert_grep "t1 [key=api] needs-decision: pick A or B" "$out" \
    "a buried needs-decision must appear on the empty-queue fast path"
  pass "buried decision surfaces in OPEN DECISIONS on the empty-queue fast path"
}

test_resolved_decision_absent() {
  local dir state out err
  dir=$(make_case resolved-absent); state="$dir/state"
  out="$dir/out"; err="$dir/err"
  printf 'blocked [key=x]: waiting on input\nresolved [key=x]: input arrived\n' > "$state/t2.status"
  run_drain "$state" "$out" "$err" || fail "drain failed"
  assert_no_grep "key=x" "$out" "a resolved decision must not appear in the section"
  assert_no_grep "OPEN DECISIONS" "$out" "no open decisions must leave the section silent"
  pass "a resolved decision is folded out and the clean drain stays quiet"
}

test_nonempty_drain_preserves_raw_and_annotations() {
  local dir state out err
  dir=$(make_case nonempty); state="$dir/state"
  out="$dir/out"; err="$dir/err"
  printf 'needs-decision [key=api]: pick A or B\ndone: unrelated finish\n' > "$state/t1.status"
  append_wake "$state" signal t1.status "signal: $state/t1.status" || fail "append failed"
  run_drain "$state" "$out" "$err" || fail "non-empty drain failed"
  # Existing behavior: the raw dedup row and the last-line annotation still print.
  assert_grep "$(printf '\tsignal\tt1.status\t')" "$out" "raw wake row must still print"
  assert_grep "wake annotation:" "$out" "the last-line annotation must still print"
  # And the new section surfaces the decision the last line no longer shows.
  assert_grep "t1 [key=api] needs-decision: pick A or B" "$out" \
    "the buried decision must also surface on a non-empty drain"
  pass "non-empty drain keeps raw rows and annotations and adds the section"
}

test_unreadable_and_symlink_skipped_without_noise() {
  local dir state out err
  dir=$(make_case skip-quietly); state="$dir/state"
  out="$dir/out"; err="$dir/err"
  # A real open decision that must still appear.
  printf 'needs-review: built the thing\n' > "$state/real.status"
  # A symlinked status file: skipped by the [ -L ] guard, never duplicated.
  ln -s "$state/real.status" "$state/link.status"
  # An unreadable status file: skipped silently, no redirection error on stderr.
  printf 'needs-decision [key=z]: never readable\n' > "$state/locked.status"
  chmod 000 "$state/locked.status"
  run_drain "$state" "$out" "$err"
  chmod 644 "$state/locked.status"
  assert_grep "real [key=default] needs-review: built the thing" "$out" \
    "the readable open decision must appear"
  assert_no_grep "link " "$out" "a symlinked status file must not produce its own line"
  assert_no_grep "locked" "$out" "an unreadable status file must not appear"
  [ ! -s "$err" ] || fail "unreadable/symlinked status files must not leak stderr noise: $(cat "$err")"
  pass "unreadable and symlinked status files are skipped without stderr noise"
}

test_clean_drain_prints_no_section() {
  local dir state out err
  dir=$(make_case clean); state="$dir/state"
  out="$dir/out"; err="$dir/err"
  printf 'working: humming along\n' > "$state/t1.status"
  run_drain "$state" "$out" "$err" || fail "clean drain failed"
  assert_no_grep "OPEN DECISIONS" "$out" "a drain with no open decisions must add no section noise"
  pass "a clean drain prints no OPEN DECISIONS section"
}

test_scan_wrapper_folds_whole_fleet() {
  local dir state out
  dir=$(make_case wrapper); state="$dir/state"
  printf 'working: a\nneeds-decision [key=one]: first\n' > "$state/alpha.status"
  printf 'blocked [key=two]: second\nresolved [key=two]: closed\n' > "$state/beta.status"
  printf 'needs-review: third\n' > "$state/gamma.status"
  out=$(scan_wrapper "$state")
  assert_contains "$out" "$(printf 'alpha\tone\tneeds-decision\tfirst')" \
    "wrapper must fold an open decision from alpha"
  assert_contains "$out" "$(printf 'gamma\tdefault\tneeds-review\tthird')" \
    "wrapper must fold gamma's default-keyed open decision"
  assert_not_contains "$out" "beta" "wrapper must not emit beta's resolved decision"
  pass "scan_open_decisions folds every task and drops resolved decisions"
}

test_fold_guards_symlink_and_unreadable() {
  local dir state out
  dir=$(make_case fold-guards); state="$dir/state"
  # Symlink to a file with a real open decision: the [ -L ] guard skips it.
  printf 'needs-decision [key=k]: open\n' > "$state/target.status"
  ln -s "$state/target.status" "$state/sym.status"
  out=$(fold_one "$state/sym.status" 2> "$dir/sym.err")
  [ -z "$out" ] || fail "a symlinked status file must fold to nothing (got: $out)"
  [ ! -s "$dir/sym.err" ] || fail "symlink skip must be silent: $(cat "$dir/sym.err")"
  # Unreadable regular file: skipped silently, no redirection error.
  printf 'blocked [key=k]: open\n' > "$state/locked.status"
  chmod 000 "$state/locked.status"
  out=$(fold_one "$state/locked.status" 2> "$dir/locked.err")
  chmod 644 "$state/locked.status"
  [ -z "$out" ] || fail "an unreadable status file must fold to nothing (got: $out)"
  [ ! -s "$dir/locked.err" ] || fail "unreadable skip must be silent: $(cat "$dir/locked.err")"
  pass "status_open_decisions skips symlinked and unreadable files silently"
}

test_buried_decision_surfaces_on_empty_drain
test_resolved_decision_absent
test_nonempty_drain_preserves_raw_and_annotations
test_unreadable_and_symlink_skipped_without_noise
test_clean_drain_prints_no_section
test_scan_wrapper_folds_whole_fleet
test_fold_guards_symlink_and_unreadable
