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

# --- a shell change moves the shell lanes -------------------------------------

out=$(lanes_for bin/cs-doctor.sh)
for lane in lint coverage portable herdr; do
  assert_lane "$out" "$lane" true "a bin/ change needs $lane"
done
assert_lane "$out" web false "a bin/ change does not need the docs site"
assert_lane "$out" docker false "a bin/ change does not need the real-docker lane"
out=$(lanes_for tests/cs-doctor.test.sh)
for lane in lint coverage portable herdr; do
  assert_lane "$out" "$lane" true "a tests/ change needs $lane"
done
assert_lane "$out" web false "a tests/ change does not need the docs site"
assert_lane "$out" docker false "a tests/ change does not need the real-docker lane"
out=$(lanes_for .github/workflows/ci.yml)
for lane in lint coverage portable herdr docker web; do
  assert_lane "$out" "$lane" true "a workflow change needs $lane"
done
pass 'shell changes run the shell lanes; workflow changes run every lane'

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

# --- vendored Grok Bot content is a portable-suite dependency ---------------

out=$(lanes_for grokbot/README.md)
assert_lane "$out" portable true "grokbot content is a portable-suite dependency"
assert_lane "$out" lint false "grokbot content cannot change the lint verdict"
assert_lane "$out" herdr false "grokbot content cannot change the real-herdr verdict"
assert_lane "$out" coverage false "grokbot content cannot change the lane partition"
pass 'grokbot changes run only the hermetic suite'

out=$(lanes_for .cursor/environment.json)
assert_lane "$out" portable true '.cursor/environment.json is a portable-suite dependency'
assert_lane "$out" lint false '.cursor/environment.json cannot change the lint verdict'
assert_lane "$out" herdr false '.cursor/environment.json cannot change the real-herdr verdict'
assert_lane "$out" coverage false '.cursor/environment.json cannot change the lane partition'
assert_lane "$out" docker false '.cursor/environment.json does not change the Compose image'
pass '.cursor/environment.json runs the portable suite'

# --- dev-tools suite changes need lint, portable, and the real-docker lane ---

out=$(lanes_for mise-tasks/dev/test)
assert_lane "$out" lint true "a mise-tasks/dev change needs shellcheck coverage"
assert_lane "$out" portable true "a mise-tasks/dev change is a portable-suite dependency"
assert_lane "$out" docker true "a mise-tasks/dev change needs the real-docker lane"
assert_lane "$out" herdr false "a mise-tasks/dev change cannot change the real-herdr verdict"
assert_lane "$out" coverage false "a mise-tasks/dev change cannot change the lane partition"
assert_lane "$out" web false "a mise-tasks/dev change does not need the docs site"
pass 'dev-tools suite changes run lint, portable, and real-docker only'

# --- a change no lane reads ---------------------------------------------------

out=$(lanes_for AGENTS.md .gitignore)
for lane in lint coverage portable herdr docker web; do
  assert_lane "$out" "$lane" false "AGENTS.md/.gitignore does not need $lane"
done
pass 'a change no lane reads skips every filtered lane'

# --- mixed change unions the lanes -------------------------------------------

out=$(lanes_for AGENTS.md docs/herdr.md bin/cs-lint.sh)
for lane in lint coverage portable herdr; do
  assert_lane "$out" "$lane" true "a mixed change unions into $lane"
done
assert_lane "$out" web false "a mixed shell/docs change does not need the docs site"
assert_lane "$out" docker false "a mixed shell/docs change does not need the real-docker lane"
pass 'a mixed change unions every triggered lane'

# --- docs site changes run only the web lane ---------------------------------

out=$(lanes_for web/package.json)
assert_lane "$out" web true "a web/ change needs the docs-site lane"
for lane in lint coverage portable herdr docker; do
  assert_lane "$out" "$lane" false "a web/ change does not need $lane"
done
pass 'docs site changes run only the web lane'

# --- mise.toml is shared by docker and the docs site --------------------------

out=$(lanes_for mise.toml)
assert_lane "$out" web true "mise.toml is a docs-site toolchain pin"
assert_lane "$out" docker true "mise.toml is a real-docker toolchain pin"
assert_lane "$out" lint true "mise.toml is in the shellcheck set via the docker lane"
assert_lane "$out" portable true "mise.toml is a portable-suite dependency"
assert_lane "$out" herdr false "mise.toml cannot change the real-herdr verdict"
pass 'mise.toml runs docker and web together'

# --- fail-open cases ----------------------------------------------------------


zero=0000000000000000000000000000000000000000
check_fail_open() {
  local label=$1 out
  shift
  out=$("$BIN" "$@" 2>/dev/null)
  for lane in lint coverage portable herdr docker web; do
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
for lane in lint coverage portable herdr docker web; do
  assert_lane "$out" "$lane" false "an empty change set skips $lane"
done
pass 'an empty change set skips every filtered lane'

# --- real refs ----------------------------------------------------------------

out=$("$BIN" HEAD HEAD 2>/dev/null)
for lane in lint coverage portable herdr docker web; do
  assert_lane "$out" "$lane" false 'a no-op diff of real refs skips every lane'
done
pass 'the two-ref form diffs real commits'

# --- the workflow gates on exactly these lanes -------------------------------

WF="$ROOT/.github/workflows/ci.yml"
for lane in lint coverage portable herdr docker web; do
  assert_grep "outputs.$lane == 'true'" "$WF" "the workflow must gate a job on the $lane lane"
done
assert_grep 'bin/cs-ci-lanes.sh' "$WF" 'the workflow must call the lane map, not re-spell it'
# A paths:/paths-ignore: KEY (not the word in a comment) would stop the workflow
# from reporting its checks at all, which is the failure mode job-level if: avoids.
! grep -Eq '^[[:space:]]*paths(-ignore)?:' "$WF" ||
  fail 'the workflow must gate with job-level if:, never a paths: filter that never reports'
pass 'the workflow gates on this script'

pass 'cs-ci-lanes behaviors'
