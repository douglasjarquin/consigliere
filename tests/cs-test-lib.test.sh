#!/usr/bin/env bash
# Behavior (portable): tests/lib.sh's temp-root registry actually cleans up.
#
# This exists because the registry was silently dead for the whole suite's life.
# cs_test_tmproot is used as `TMP=$(cs_test_tmproot foo)`, so its body runs in a
# command-substitution subshell; the old implementation appended to a shell array
# and installed the EXIT trap from inside that subshell, so neither ever reached
# the caller. Every suite leaked its temp dir (394 had accumulated in TMPDIR), and
# leaked fixture repos are what got accidentally trusted into the boss's codex
# config. Nothing failed, so nothing noticed - hence these regressions.
#
# Each case runs a throwaway script in a CHILD bash process, because the contract
# under test is what happens when a shell EXITs.
#
# Every single-quoted block below is child-script TEXT: the `$...` in it must
# reach the child unexpanded, so SC2016 is the intended shape here, not a bug.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(cs_test_tmproot cs-test-lib)
PATHS="$TMP/paths"

# run_child <script-body> - run body in a child bash that sources lib.sh, and
# leave its output in $OUT. The child writes any dirs it made to $PATHS.
run_child() {
  OUT=$(PATHS="$PATHS" ROOT="$ROOT" bash -c "
    set -u
    . \"\$ROOT/tests/lib.sh\"
    $1
  " 2>&1)
}

# --- 1. a dir made through command substitution is cleaned on exit -----------
# The exact call shape every suite uses, and the one the old array could not see.
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
  assert_absent "$d" "temp root from a command substitution must be removed on exit"
done < "$PATHS"
pass "cs_test_tmproot registers through a command substitution and cleans up on exit"

# --- 2. the registry file itself does not leak -------------------------------
run_child '
A=$(cs_test_tmproot probe-reg)
printf "%s\n" "$CS_TEST_REGISTRY" > "$PATHS"
'
reg=$(head -1 "$PATHS")
[ -n "$reg" ] || fail "child did not report its registry path"
assert_absent "$reg" "the registry file must be consumed, not left in TMPDIR"
pass "the registry file is removed with the dirs it tracked"

# --- 3. a suite's own EXIT trap still gets cleanup ---------------------------
# Six suites install their own EXIT trap (lab teardown, daemon kill) and call
# cs_test_cleanup from it. That override replaces lib.sh's trap, so cleanup has to
# come from their handler - assert it still lands.
run_child '
own() { echo "own-teardown"; cs_test_cleanup; }
trap own EXIT
A=$(cs_test_tmproot probe-own)
printf "%s\n" "$A" > "$PATHS"
'
assert_contains "$OUT" "own-teardown" "the suite's own handler must still run"
d=$(head -1 "$PATHS")
assert_absent "$d" "a suite that overrides the trap and calls cs_test_cleanup still cleans up"
pass "an overriding EXIT trap that calls cs_test_cleanup still removes temp roots"

# --- 4. cs_test_cleanup is safe to call twice --------------------------------
run_child '
A=$(cs_test_tmproot probe-twice)
printf "%s\n" "$A" > "$PATHS"
cs_test_cleanup
cs_test_cleanup
echo "second-call-ok"
'
assert_contains "$OUT" "second-call-ok" "a second cs_test_cleanup must not error"
d=$(head -1 "$PATHS")
assert_absent "$d" "the first cleanup removed the dir"
pass "cs_test_cleanup is idempotent"

# --- 5. a corrupted registry never becomes an rm -rf on something else -------
# The registry is a plain file, so treat its contents as untrusted: only a path
# under the temp base, with a real leaf and no traversal, may be removed. The
# probe paths are chosen to exist on both macOS and the Ubuntu CI runner, and to
# sit outside TMPDIR on both. The temp base ITSELF is in the list deliberately: a
# bare base with no leaf must be refused, or one bad line would wipe TMPDIR.
: > "$PATHS"
run_child '
A=$(cs_test_tmproot probe-guard)
printf "%s\n" "/" "/etc" "$HOME" "../../etc" "$CS_TEST_TMPBASE" "$CS_TEST_TMPBASE/" "$CS_TEST_TMPBASE/." >> "$CS_TEST_REGISTRY"
printf "%s\n%s\n" "$A" "$CS_TEST_TMPBASE" > "$PATHS"
'
assert_present / "/ must survive a corrupted registry"
assert_present /etc "/etc must survive a corrupted registry"
assert_present "$HOME" "\$HOME must survive a corrupted registry"
base=$(sed -n 2p "$PATHS")
[ -n "$base" ] || fail "child did not report the temp base"
assert_present "$base" "the temp base itself must survive a corrupted registry"
d=$(head -1 "$PATHS")
assert_absent "$d" "the child's own temp root is still cleaned"
pass "a corrupted registry cannot remove the temp base or anything outside it"

: > "$PATHS"
OUT=$(TMPDIR=/ PATHS="$PATHS" ROOT="$ROOT" bash -c '
  set -u
  . "$ROOT/tests/lib.sh"
  A=$(cs_test_tmproot probe-root)
  printf "%s\n%s\n" "$A" "$CS_TEST_TMPBASE" > "$PATHS"
  printf "%s\n" "/etc" >> "$CS_TEST_REGISTRY"
' 2>&1)
d=$(head -1 "$PATHS")
[ -n "$d" ] || fail "root TMPDIR child did not report its temp root: $OUT"
assert_present /etc "TMPDIR=/ must not make /etc removable"
assert_absent "$d" "the root TMPDIR child still cleans its temp root"
pass "TMPDIR=/ cannot broaden corrupted-registry cleanup"

# --- 6. a suite that never makes a temp root exits cleanly -------------------
# lib.sh installs the trap at source time now, so the no-registry path must be a
# silent no-op rather than an error on every such suite.
run_child 'echo "no-tmproot-ok"'
assert_contains "$OUT" "no-tmproot-ok" "sourcing lib.sh without cs_test_tmproot must not fail"
assert_not_contains "$OUT" "No such file" "the empty-registry path must be silent"
pass "a suite that never calls cs_test_tmproot exits silently"

pass "tests/lib.sh temp-root registry behavior"
