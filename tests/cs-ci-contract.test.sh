#!/usr/bin/env bash
# Behavior (portable): the CI contract. Protects the guarantees that let hosted
# CI, local runs, and the coverage guard stay in lockstep, so a change that would
# silently weaken CI fails this hermetic test first.
#
# Covers: the lane partition and coverage guard; single-owner pins (ShellCheck
# version, Herdr version + protocol floor); and the workflow calling only the
# repository-owned entrypoints (no re-spelled commands, live-codex never run in
# hosted CI).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WF="$ROOT/.github/workflows/ci.yml"
RUN="$ROOT/bin/cs-test-run.sh"
LINT="$ROOT/bin/cs-lint.sh"

# --- lane partition + coverage guard ---------------------------------------

# The ok summary goes to stdout; the "excluded" report goes to stderr, so
# capture both.
out=$("$RUN" --check-coverage 2>&1) || fail "coverage guard must exit 0 on a healthy tree"
assert_contains "$out" "CS_TEST_COVERAGE ok" "coverage guard prints its ok summary"
pass "coverage guard passes"

inventory=( "$ROOT"/tests/*.test.sh )
all_count=${#inventory[@]}
p=$("$RUN" --list --portable | grep -c .)
h=$("$RUN" --list --herdr | grep -c .)
c=$("$RUN" --list --lane live-codex | grep -c .)
cl=$("$RUN" --list --lane live-claude | grep -c .)
[ "$((p + h + c + cl))" -eq "$all_count" ] \
  || fail "lanes ($p+$h+$c+$cl) must sum to the inventory ($all_count)"
pass "portable + real-herdr + live-codex + live-claude partition the whole inventory"

# No script may appear in two lanes.
dups=$({ "$RUN" --list --portable; "$RUN" --list --herdr; "$RUN" --list --lane live-codex; "$RUN" --list --lane live-claude; } \
  | LC_ALL=C sort | uniq -d)
[ -z "$dups" ] || fail "a test is categorized into more than one lane: $dups"
pass "no test appears in two lanes"

# The live-only families keep their exact, self-gating lane.
[ "$("$RUN" --lane-of cs-herdr-lib-live.test.sh)" = "real-herdr" ] \
  || fail "cs-herdr-lib-live must be the real-herdr lane"
[ "$("$RUN" --lane-of cs-lifecycle-live.test.sh)" = "live-codex" ] \
  || fail "cs-lifecycle-live must be the live-codex lane"
[ "$("$RUN" --lane-of cs-lifecycle-claude-live.test.sh)" = "live-claude" ] \
  || fail "cs-lifecycle-claude-live must be the live-claude lane"
assert_contains "$out" "excluded (CS_TEST_CODEX_LIVE)" \
  "coverage guard reports live-codex as visibly excluded, not silently dropped"
assert_contains "$out" "excluded (CS_TEST_CLAUDE_LIVE)" \
  "coverage guard reports live-claude as visibly excluded, not silently dropped"
pass "live-only lanes are pinned and live-codex is visibly excluded"

# --- single-owner pins ------------------------------------------------------

# ShellCheck version: cs-lint.sh owns it; the installer reads it, never re-pins.
sc_version=$("$LINT" --required-version)
[ -n "$sc_version" ] || fail "cs-lint.sh --required-version must print a version"
# shellcheck disable=SC2016  # literal grep pattern; no expansion wanted
assert_grep '"$ROOT/bin/cs-lint.sh" --required-version' "$ROOT/bin/cs-install-shellcheck.sh" \
  "cs-install-shellcheck.sh must read the version from cs-lint.sh"
assert_no_grep 'REQUIRED_SHELLCHECK=' "$ROOT/bin/cs-install-shellcheck.sh" \
  "cs-install-shellcheck.sh must not re-declare the ShellCheck version"
pass "ShellCheck version has one owner (cs-lint.sh)"

# Herdr protocol floor: cs-herdr-lib.sh owns it; the installer reads it.
floor=$(awk -F= '/^CS_HERDR_MIN_PROTOCOL=/ { gsub(/[^0-9]/, "", $2); print $2; exit }' \
  "$ROOT/bin/cs-herdr-lib.sh")
[ -n "$floor" ] || fail "cs-herdr-lib.sh must define CS_HERDR_MIN_PROTOCOL"
assert_grep 'CS_HERDR_MIN_PROTOCOL=' "$ROOT/bin/cs-install-herdr.sh" \
  "cs-install-herdr.sh must read the protocol floor from cs-herdr-lib.sh"
# Derive the pin instead of restating it. cs-install-herdr.sh's header calls
# itself "the single owner of the exact Herdr version"; a hard-coded copy here
# is a second owner that has to be remembered on every bump, and this assertion
# previously pinned 0.7.4 purely because nobody updated it.
herdr_pin=$(awk -F= '/^CS_HERDR_CI_VERSION=/ { print $2; exit }' "$ROOT/bin/cs-install-herdr.sh" | tr -d '[:space:]')
case "$herdr_pin" in
  ''|*[!0-9.]*) fail "cs-install-herdr.sh must define CS_HERDR_CI_VERSION as a bare version, got '${herdr_pin:-<empty>}'" ;;
esac
assert_grep "$herdr_pin" "$ROOT/docs/herdr.md" \
  "docs/herdr.md must document the pinned Herdr version ($herdr_pin)"
assert_grep "\"\$version\" = \"$herdr_pin\"" "$ROOT/.github/workflows/ci.yml" \
  "ci.yml's post-install version gate must assert the same pin ($herdr_pin)"
pass "Herdr version pinned and protocol floor has one owner (cs-herdr-lib.sh)"

# --- workflow calls only the repository-owned entrypoints -------------------

[ -f "$WF" ] || fail "missing .github/workflows/ci.yml"
for entry in \
  'bin/cs-lint.sh' \
  'bin/cs-install-shellcheck.sh' \
  'bin/cs-install-herdr.sh' \
  'bin/cs-herdr-ci-cleanup.sh' \
  'bin/cs-ci-lanes.sh' \
  'bin/cs-test-run.sh --check-coverage' \
  'bin/cs-test-run.sh --portable' \
  'bin/cs-test-run.sh --herdr'; do
  assert_grep "$entry" "$WF" "workflow must call $entry"
done
pass "workflow calls the repository-owned lint, test, install, and cleanup entrypoints"

# The workflow must not re-spell the lint command that cs-lint.sh owns.
assert_no_grep 'shellcheck --norc' "$WF" "workflow must not re-spell the shellcheck command"
assert_no_grep 'shellcheck bin/' "$WF" "workflow must not re-spell the shellcheck file set"
pass "workflow does not duplicate the lint definition"

# Live agent tests must never run in hosted CI.
assert_no_grep 'CS_TEST_CODEX_LIVE' "$WF" \
  "hosted CI must never enable CS_TEST_CODEX_LIVE (live-codex is opt-in only)"
assert_no_grep 'CS_TEST_CLAUDE_LIVE' "$WF" \
  "hosted CI must never enable CS_TEST_CLAUDE_LIVE (live-claude is opt-in only)"
assert_grep 'CS_TEST_HERDR_LIVE' "$WF" "the Herdr lane must enable CS_TEST_HERDR_LIVE"
pass "hosted CI runs real Herdr but never the live-codex or live-claude suites"

# Least-privilege + superseded-run cancellation.
assert_grep 'contents: read' "$WF" "workflow must use least-privilege contents: read"
assert_grep 'cancel-in-progress: true' "$WF" "workflow must cancel superseded runs"
pass "workflow is least-privilege and cancels superseded runs"

# --- lane gating keeps the invariants job unconditional ----------------------
#
# The repo-invariants job is the one lane that must run for every change, because
# any commit at all can track a boss-private path or flatten a tracked symlink.
# A filter on it would be a silent hole, so assert its block carries no gate.
invariants_block=$(awk '
  /^  invariants:/ { inside = 1; next }
  inside && /^  [a-z][a-z0-9-]*:/ { exit }
  inside { print }
' "$WF")
[ -n "$invariants_block" ] || fail "could not find the invariants job in the workflow"
assert_not_contains "$invariants_block" 'needs: changes' \
  "the repo-invariants job must not depend on the lane filter"
assert_not_contains "$invariants_block" 'if:' \
  "the repo-invariants job must stay unconditional"
pass "repo invariants run for every change, including docs-only ones"
