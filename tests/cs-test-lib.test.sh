#!/usr/bin/env bash
# Behavior (portable): tests/lib.sh's temp-root registry actually cleans up.
#
# This suite exists because the registry was silently dead for the whole life of
# the test suite. cs_test_tmproot is used as `TMP_ROOT=$(cs_test_tmproot foo)`, so
# its body ran in a command-substitution subshell; the old implementation appended
# to a shell array and installed the EXIT trap from inside that subshell, so
# neither ever reached the caller. Every suite leaked its whole fixture tree on
# every run, fixture git repos included, and nothing failed - so nothing noticed.
# These cases are what makes that failure mode loud instead of invisible.
#
# Each case runs a throwaway script in a CHILD bash, because the contract under
# test is what happens when a shell EXITs. A child reports the paths it made
# through $PATHS so the parent can assert on them after the child is gone.
#
# Every single-quoted block below is child-script TEXT: the `$...` in it must
# reach the child unexpanded, so SC2016 is the intended shape here, not a bug.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(cs_test_tmproot cs-test-lib)
PATHS="$TMP/paths"

# run_child <script-body> - run body in a child bash that sources lib.sh, leaving
# its combined output in $OUT.
run_child() {
  OUT=$(PATHS="$PATHS" ROOT="$ROOT" bash -c "
    set -u
    . \"\$ROOT/tests/lib.sh\"
    $1
  " 2>&1)
}

# --- 1. the exact call shape every suite uses --------------------------------
: > "$PATHS"
run_child '
A=$(cs_test_tmproot probe-a)
B=$(cs_test_tmproot probe-b)
printf "%s\n%s\n" "$A" "$B" > "$PATHS"
[ -d "$A" ] && [ -d "$B" ] || { echo "dirs not created"; exit 1; }
'
[ -s "$PATHS" ] || fail "child did not report its temp dirs: $OUT"
while IFS= read -r d; do
  [ -n "$d" ] || continue
  assert_absent "$d" "a temp root made through a command substitution must be removed on exit"
done < "$PATHS"
pass "cs_test_tmproot registers through a command substitution and cleans up on exit"

# --- 2. the registry file does not leak either -------------------------------
: > "$PATHS"
run_child '
A=$(cs_test_tmproot probe-reg)
printf "%s\n" "$CS_TEST_REGISTRY" > "$PATHS"
'
reg=$(head -1 "$PATHS")
[ -n "$reg" ] || fail "child did not report its registry path: $OUT"
assert_absent "$reg" "the registry file must be consumed, not left behind in the temp base"
pass "the registry file is removed along with the dirs it tracked"

# --- 3. a suite's own EXIT trap still gets cleanup ---------------------------
# Several suites install their own EXIT trap (lab teardown, daemon kill) and call
# cs_test_cleanup from it. That override replaces lib.sh's trap, so cleanup has to
# arrive through their handler - assert it still lands.
: > "$PATHS"
run_child '
own() { echo "own-teardown"; cs_test_cleanup; }
trap own EXIT
A=$(cs_test_tmproot probe-own)
printf "%s\n" "$A" > "$PATHS"
'
assert_contains "$OUT" "own-teardown" "the suite's own EXIT handler must still run"
d=$(head -1 "$PATHS")
assert_absent "$d" "a suite that overrides the trap and calls cs_test_cleanup still cleans up"
pass "an overriding EXIT trap that calls cs_test_cleanup still removes temp roots"

# --- 4. cleaning twice is not an error --------------------------------------
run_child '
A=$(cs_test_tmproot probe-twice)
cs_test_cleanup
cs_test_cleanup
echo "survived-double-cleanup"
'
assert_contains "$OUT" "survived-double-cleanup" \
  "calling cs_test_cleanup twice must be silent, not an error: $OUT"
pass "cs_test_cleanup is idempotent"

# --- 5. a corrupted registry cannot rm anything the library did not mint -----
# The registry is a plain file, so treat its contents as untrusted. Only an
# IMMEDIATE child of the temp base may be removed, which is all mktemp -d ever
# produces: a nested path, the bare temp base, a traversal, and / must be refused.
keep="$TMP/must-survive"
mkdir -p "$keep/inner"
: > "$PATHS"
run_child "
A=\$(cs_test_tmproot probe-guard)
{
  printf '%s\n' '$keep'
  printf '%s\n' \"\$CS_TEST_TMPBASE/..\"
  printf '%s\n' \"\$CS_TEST_TMPBASE\"
  printf '%s\n' /
} >> \"\$CS_TEST_REGISTRY\"
printf '%s\n' \"\$A\" > \"\$PATHS\"
"
assert_present "$keep/inner" "a registry path nested below the temp base was removed anyway"
assert_present "$TMP" "the guard removed a path it had no business touching"
assert_present "$CS_TEST_TMPBASE" "the bare temp base must never be removed"
d=$(head -1 "$PATHS")
assert_absent "$d" "the guard must still remove the dirs the library really minted"
pass "a corrupted registry cannot turn cleanup into an rm -rf elsewhere"

# --- 6. a suite that never makes a temp root exits clean --------------------
run_child '
echo "no-temp-root-needed"
'
assert_contains "$OUT" "no-temp-root-needed" "a suite with no temp root must exit silently: $OUT"
assert_not_contains "$OUT" "No such file" "cleanup complained about a registry that was never used"
pass "a suite that never calls cs_test_tmproot exits without complaint"

# --- 7. a registry left by a dead run is not inherited ---------------------
# Pids recycle, so a registry file can already exist at this shell's own path when
# lib.sh is sourced. Its contents belong to a dead run and must not be adopted as
# this suite's list, or cleanup would delete dirs it never created. The child
# seeds the file at its OWN $$-derived path BEFORE sourcing, which is the only way
# to reach the case lib.sh's source-time truncation exists for.
: > "$PATHS"
OUT=$(PATHS="$PATHS" ROOT="$ROOT" KEEP="$keep" bash -c '
  set -u
  base="${TMPDIR:-/tmp}"; base="${base%/}"
  printf "%s\n" "$KEEP" > "$base/cs-test-reg.$$"
  . "$ROOT/tests/lib.sh"
  A=$(cs_test_tmproot probe-stale)
  printf "%s\n" "$A" > "$PATHS"
' 2>&1)
assert_present "$keep/inner" "a stale registry's contents were adopted and deleted: $OUT"
d=$(head -1 "$PATHS")
[ -n "$d" ] || fail "child did not report its temp dir: $OUT"
assert_absent "$d" "truncating the stale registry must not stop this run's own dirs being cleaned"
pass "a registry file left by a dead run is truncated, not inherited"

pass "tests/lib.sh temp-root registry contract"
