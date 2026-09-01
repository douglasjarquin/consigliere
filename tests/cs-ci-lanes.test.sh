#!/usr/bin/env bash
# Behavior (portable): cs-ci-lanes.sh maps changed paths to CI lanes, and fails
# open whenever the change set cannot be determined. A wrongly-skipped lane is a
# silent false green, so the fail-open cases matter more than the happy path.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BIN="$ROOT/bin/cs-ci-lanes.sh"

# lanes_for <path>... - the lane decisions for a change touching those paths.
lanes_for() {
  printf '%s\n' "$@" | "$BIN" --paths-from - 2>/dev/null
}

assert_lane() {
  local out=$1 lane=$2 want=$3 label=$4 got
  got=$(printf '%s\n' "$out" | awk -F= -v l="$lane" '$1 == l { print $2; exit }')
  [ "$got" = "$want" ] || fail "$label: $lane=$got, wanted $lane=$want"
}

# --- usage --------------------------------------------------------------------

"$BIN" --help >/dev/null 2>&1
expect_code 0 "$?" '--help exits 0'
"$BIN" >/dev/null 2>&1
expect_code 2 "$?" 'no argument is a usage error'
"$BIN" --bogus >/dev/null 2>&1
expect_code 2 "$?" 'an unknown option is a usage error'
pass 'usage handling'

# --- a shell change moves every lane ------------------------------------------

out=$(lanes_for bin/cs-doctor.sh)
for lane in lint coverage portable herdr; do
  assert_lane "$out" "$lane" true "a bin/ change needs $lane"
done
out=$(lanes_for tests/cs-doctor.test.sh)
for lane in lint coverage portable herdr; do
  assert_lane "$out" "$lane" true "a tests/ change needs $lane"
done
out=$(lanes_for .github/workflows/ci.yml)
for lane in lint coverage portable herdr; do
  assert_lane "$out" "$lane" true "a workflow change needs $lane"
done
pass 'shell and workflow changes run every lane'

# --- content the hermetic suite asserts on, but no shell lane reads -----------
#
# These four are real test dependencies: the CI contract test asserts the pinned
# herdr version in docs/herdr.md, the rundown test asserts skills/rundown/SKILL.md
# and its README inventory entry, and the decision-hold test copies .tasks.toml.

for path in docs/herdr.md skills/rundown/SKILL.md README.md .tasks.toml; do
  out=$(lanes_for "$path")
  assert_lane "$out" portable true "$path is a portable-suite dependency"
  assert_lane "$out" lint false "$path cannot change the lint verdict"
  assert_lane "$out" herdr false "$path cannot change the real-herdr verdict"
  assert_lane "$out" coverage false "$path cannot change the lane partition"
done
pass 'documentation and skill changes run only the hermetic suite'

# --- a change no lane reads ---------------------------------------------------

out=$(lanes_for AGENTS.md .gitignore)
for lane in lint coverage portable herdr; do
  assert_lane "$out" "$lane" false "AGENTS.md/.gitignore does not need $lane"
done
pass 'a change no lane reads skips every filtered lane'

# --- mixed change unions the lanes -------------------------------------------

out=$(lanes_for AGENTS.md docs/herdr.md bin/cs-lint.sh)
for lane in lint coverage portable herdr; do
  assert_lane "$out" "$lane" true "a mixed change unions into $lane"
done
pass 'a mixed change unions every triggered lane'

# --- fail-open cases ----------------------------------------------------------

zero=0000000000000000000000000000000000000000
check_fail_open() {
  local label=$1 out
  shift
  out=$("$BIN" "$@" 2>/dev/null)
  for lane in lint coverage portable herdr; do
    assert_lane "$out" "$lane" true "$label must fail open into $lane"
  done
}

check_fail_open 'an all-zero base sha (fresh branch or force-push)' "$zero" HEAD
check_fail_open 'a base ref absent from the clone' deadbeefdeadbeefdeadbeefdeadbeefdeadbeef HEAD
check_fail_open 'a head ref absent from the clone' HEAD deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
check_fail_open 'an empty base ref' '' HEAD

TMP=$(cs_test_tmproot cs-ci-lanes)
check_fail_open 'a missing path list' --paths-from "$TMP/absent.txt"

# Fail-open must be loud in the log, not silent.
err=$("$BIN" "$zero" HEAD 2>&1 >/dev/null)
assert_contains "$err" 'running every lane' 'fail-open explains itself in the CI log'
pass 'an undeterminable change set runs every lane, loudly'

# --- an empty change set ------------------------------------------------------

out=$(printf '' | "$BIN" --paths-from - 2>/dev/null)
for lane in lint coverage portable herdr; do
  assert_lane "$out" "$lane" false "an empty change set skips $lane"
done
pass 'an empty change set skips every filtered lane'

# --- real refs ----------------------------------------------------------------

out=$("$BIN" HEAD HEAD 2>/dev/null)
for lane in lint coverage portable herdr; do
  assert_lane "$out" "$lane" false 'a no-op diff of real refs skips every lane'
done
pass 'the two-ref form diffs real commits'

# --- the workflow gates on exactly these lanes -------------------------------

WF="$ROOT/.github/workflows/ci.yml"
for lane in lint coverage portable herdr; do
  assert_grep "outputs.$lane == 'true'" "$WF" "the workflow must gate a job on the $lane lane"
done
assert_grep 'bin/cs-ci-lanes.sh' "$WF" 'the workflow must call the lane map, not re-spell it'
# A paths:/paths-ignore: KEY (not the word in a comment) would stop the workflow
# from reporting its checks at all, which is the failure mode job-level if: avoids.
! grep -Eq '^[[:space:]]*paths(-ignore)?:' "$WF" ||
  fail 'the workflow must gate with job-level if:, never a paths: filter that never reports'
pass 'the workflow gates on this script'

pass 'cs-ci-lanes behaviors'
