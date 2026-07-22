#!/usr/bin/env bash
# Behavior: cs-lock.sh acquires the per-home session lock against the harness
# ancestry PID, refuses while a live holder exists, adopts a stale holder, and
# reports status without mutating.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(cs_test_tmproot cs-lock)
export CS_STATE_OVERRIDE="$TMP/state"
# The test runs under bash, not codex; widen the ancestry match so the test
# shell itself is found as the "harness".
export CS_LOCK_HARNESS_RE='bash|zsh|codex'

# acquire on a free lock
out=$("$ROOT/bin/cs-lock.sh") || fail "acquire on free lock failed"
assert_contains "$out" "lock acquired" "acquire reports the held pid"
assert_present "$TMP/state/.lock" "lock file written"

# re-acquire by the same session is idempotent
out=$("$ROOT/bin/cs-lock.sh") || fail "re-acquire by same session failed"
assert_contains "$out" "lock acquired" "re-acquire reports success"

# a live foreign holder refuses
sleep 300 &
holder=$!
echo "$holder" > "$TMP/state/.lock"
out=$(CS_LOCK_HARNESS_RE='sleep|bash|zsh|codex' "$ROOT/bin/cs-lock.sh" 2>&1)
code=$?
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
expect_code 1 "$code" "live foreign holder refuses"
assert_contains "$out" "another live consigliere session holds the lock" "refusal names the conflict"

# a dead holder is adopted
echo 99999999 > "$TMP/state/.lock"
out=$("$ROOT/bin/cs-lock.sh") || fail "adopting a dead holder failed"
assert_contains "$out" "lock acquired" "dead holder adopted"

# status never mutates and always exits 0
echo 99999999 > "$TMP/state/.lock"
out=$("$ROOT/bin/cs-lock.sh" status)
assert_contains "$out" "stale" "status reports a stale holder"
assert_grep "99999999" "$TMP/state/.lock" "status did not rewrite the lock"

rm -f "$TMP/state/.lock"
out=$("$ROOT/bin/cs-lock.sh" status)
assert_contains "$out" "free" "status reports a free lock"

pass "cs-lock acquire/refuse/adopt/status behaviors"
