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

# --- harness identity ---------------------------------------------------------

# Claude Code's native installer names the per-session executable by version, so
# the process is .../share/claude/versions/2.1.220 and its BASENAME identifies
# nothing. Identity is therefore matched on whole path components of both the
# executable path and argv[0]. Whole components only, or the widened search
# starts calling hook scripts and unrelated directories a harness.
(
  # shellcheck disable=SC2030,SC2031 # subshell-local by design: each block pins its own harness set
  export CS_LOCK_HARNESS_RE='codex|claude'
  # shellcheck source=bin/cs-lock.sh
  . "$ROOT/bin/cs-lock.sh"

  VERSIONED=/Users/d/.local/share/claude/versions/2.1.220
  harness_process_is claude claude || fail "a plainly named harness must match"
  harness_process_is codex codex || fail "codex must match"
  harness_process_is "$VERSIONED" "$VERSIONED" \
    || fail "a version-named executable path must be recognized by its claude component"
  harness_process_is 2.1.220 "$VERSIONED --resume" \
    || fail "a version-named comm must be recognized through argv[0]"
  harness_process_is node "node /opt/x/claude/cli.js" \
    || fail "a bare interpreter must be recognized by its script path"

  # False positives the widening must not introduce.
  harness_process_is bash "bash /Users/d/.claude/hooks/foo.sh" \
    && fail "a ~/.claude hook path has no 'claude' component and must not match"
  harness_process_is bash "bash /Users/d/github/consigliere/bin/cs-claude-guard.sh" \
    && fail "a cs-claude-* script name must not read as the harness"
  harness_process_is bash "bash /Users/d/claude-tools/bin/wrapper.sh" \
    && fail "a claude-tools directory must not read as the harness"
  : # the && fail guards above leave a nonzero status behind on success
) || exit 1
pass "harness identity reads whole path components, not a basename"

# A login shell's argv[0] is "-zsh"; the dash is convention, not part of a name.
(
  # shellcheck disable=SC2030,SC2031 # subshell-local by design: each block pins its own harness set
  export CS_LOCK_HARNESS_RE='bash|zsh|codex'
  # shellcheck source=bin/cs-lock.sh
  . "$ROOT/bin/cs-lock.sh"
  harness_process_is -zsh -zsh || fail "a login shell's leading dash must be stripped"
  harness_process_is sleep sleep && fail "an unrelated process must not match"
  :
) || exit 1
pass "a login shell's leading dash is not part of the harness name"

# End to end against a controlled process table: the ancestry walk must find a
# version-named session, and - the fault that matters - a LIVE one must not have
# its lock read as stale and taken by a second session. That is how two sessions
# end up mutating one fleet.
PSDIR=$(cs_fakebin "$TMP")
sleep 300 &
LIVE=$!
cat > "$PSDIR/ps" <<PSEOF
#!/usr/bin/env bash
# Fake process table: \$LIVE is a version-named claude session; every other pid
# is a plain bash whose parent is that session.
field=\$2; pid=\$4
if [ "\$pid" = "$LIVE" ]; then
  case "\$field" in
    comm=) echo "/Users/d/.local/share/claude/versions/2.1.220" ;;
    args=) echo "/Users/d/.local/share/claude/versions/2.1.220 --resume" ;;
    ppid=) echo 1 ;;
  esac
else
  case "\$field" in
    comm=) echo bash ;;
    args=) echo bash ;;
    ppid=) echo "$LIVE" ;;
  esac
fi
PSEOF
chmod +x "$PSDIR/ps"

rm -f "$TMP/state/.lock"
out=$(PATH="$PSDIR:$PATH" CS_LOCK_HARNESS_RE='codex|claude' "$ROOT/bin/cs-lock.sh" 2>&1) \
  || fail "the walk must find a version-named harness in the ancestry: $out"
assert_contains "$out" "lock acquired: harness pid $LIVE" \
  "the version-named session, not its bash child, is recorded as the holder"

out=$(PATH="$PSDIR:$PATH" CS_LOCK_HARNESS_RE='codex|claude' "$ROOT/bin/cs-lock.sh" status 2>&1)
assert_contains "$out" "held by live harness pid $LIVE" \
  "a live version-named holder must not be reported stale"

kill "$LIVE" 2>/dev/null || true
wait "$LIVE" 2>/dev/null || true
pass "a live version-named session holds its lock instead of losing it as stale"
