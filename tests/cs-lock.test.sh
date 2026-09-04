#!/usr/bin/env bash
# Behavior: cs-lock.sh acquires the per-home session lock against the harness
# ancestry PID, refuses while a live holder exists, adopts a stale holder, and
# reports status without mutating.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset CS_TASK_ID

TMP=$(cs_test_tmproot cs-lock)
export CS_STATE_OVERRIDE="$TMP/state"
# The test runs under bash, not codex; widen the ancestry match so the test
# shell itself is found as the "harness".
export CS_LOCK_HARNESS_RE='bash|zsh|codex'

# acquire on a free lock
out=$("$ROOT/bin/cs-lock.sh") || fail "acquire on free lock failed"
assert_contains "$out" "lock acquired" "acquire reports the held pid"
assert_present "$TMP/state/.lock" "lock file written"

SOLDIER_STATE="$TMP/soldier-state"
mkdir -p "$SOLDIER_STATE"
printf 'soldier-lock-sentinel\n' > "$SOLDIER_STATE/.lock"
set +e
out=$(CS_TASK_ID=fix-soldier-lock-hijack CS_STATE_OVERRIDE="$SOLDIER_STATE" \
  "$ROOT/bin/cs-lock.sh" 2>&1)
code=$?
expect_code 1 "$code" "soldier context refuses lock acquisition"
assert_contains "$out" "soldier context" "soldier lock refusal names its context"
[ "$(cat "$SOLDIER_STATE/.lock")" = 'soldier-lock-sentinel' ] || \
  fail "soldier lock acquisition overwrote the existing lock"
pass "CS_TASK_ID prevents a soldier from acquiring the session lock"

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
  # shellcheck source=bin/cs-session-pid-lib.sh
  . "$ROOT/bin/cs-session-pid-lib.sh"

  VERSIONED=/Users/d/.local/share/claude/versions/2.1.220
  cs_session_harness_process_is claude claude || fail "a plainly named harness must match"
  cs_session_harness_process_is codex codex || fail "codex must match"
  cs_session_harness_process_is "$VERSIONED" "$VERSIONED" \
    || fail "a version-named executable path must be recognized by its claude component"
  cs_session_harness_process_is 2.1.220 "$VERSIONED --resume" \
    || fail "a version-named comm must be recognized through argv[0]"
  cs_session_harness_process_is node "node /opt/x/claude/cli.js" \
    || fail "a bare interpreter must be recognized by its script path"

  # False positives the widening must not introduce.
  cs_session_harness_process_is bash "bash /Users/d/.claude/hooks/foo.sh" \
    && fail "a ~/.claude hook path has no 'claude' component and must not match"
  cs_session_harness_process_is bash "bash /Users/d/github/consigliere/bin/cs-claude-guard.sh" \
    && fail "a cs-claude-* script name must not read as the harness"
  cs_session_harness_process_is bash "bash /Users/d/claude-tools/bin/wrapper.sh" \
    && fail "a claude-tools directory must not read as the harness"
  : # the && fail guards above leave a nonzero status behind on success
) || exit 1
pass "harness identity reads whole path components, not a basename"

# A login shell's argv[0] is "-zsh"; the dash is convention, not part of a name.
(
  # shellcheck disable=SC2030,SC2031 # subshell-local by design: each block pins its own harness set
  export CS_LOCK_HARNESS_RE='bash|zsh|codex'
  # shellcheck source=bin/cs-session-pid-lib.sh
  . "$ROOT/bin/cs-session-pid-lib.sh"
  cs_session_harness_process_is -zsh -zsh || fail "a login shell's leading dash must be stripped"
  cs_session_harness_process_is sleep sleep && fail "an unrelated process must not match"
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

# --- portable mtime owner (cs_lock_path_mtime) --------------------------------

# Regression for the GNU stat trap: `stat -f` on GNU coreutils is FILESYSTEM
# stat - it consumes the format string as a path, prints a partial dump on
# stdout, and can still exit 0, so a `stat -f %m ... || stat -c %Y ...` fallback
# never runs and downstream arithmetic evaluates garbage. The owner must probe
# the flavor and return only a pure integer.
STUBS="$TMP/stat-stubs"
mkdir -p "$STUBS"
: > "$TMP/mtime-target"

cat > "$STUBS/stat" <<'SH'
#!/usr/bin/env bash
if [ "${1-}" = -f ]; then
  printf '  File: "%s"\n    ID: 100 Namelen: 255    Type: apfs\n' "${3-}"
  exit 0
fi
if [ "${1-}" = -c ] && [ "${2-}" = %Y ]; then
  printf '1234567890\n'
  exit 0
fi
exit 1
SH
chmod 0700 "$STUBS/stat"

out=$(
  # shellcheck disable=SC2030,SC2031 # subshell-local by design: each scenario pins its own stat stub
  PATH="$STUBS:$PATH"
  unset _CS_LOCK_STAT_FLAVOR CS_LOCK_LIB_SOURCED
  # shellcheck source=bin/cs-lock-lib.sh
  . "$ROOT/bin/cs-lock-lib.sh"
  cs_lock_path_mtime "$TMP/mtime-target"
) || fail "a GNU-style stat must fall through to the -c form, not fail"
[ "$out" = 1234567890 ] || fail "GNU-style stat corrupted the mtime value: '$out'"
pass "a GNU-style stat (filesystem-dump -f that exits 0) never corrupts the mtime"

# A stat that prints garbage in BOTH forms must fail with NO output, never pass
# the garbage through into a caller's arithmetic.
cat > "$STUBS/stat" <<'SH'
#!/usr/bin/env bash
printf '  File: nonsense\n'
exit 0
SH
chmod 0700 "$STUBS/stat"
set +e
out=$(
  # shellcheck disable=SC2030,SC2031 # subshell-local by design: each scenario pins its own stat stub
  PATH="$STUBS:$PATH"
  unset _CS_LOCK_STAT_FLAVOR CS_LOCK_LIB_SOURCED
  # shellcheck source=bin/cs-lock-lib.sh
  . "$ROOT/bin/cs-lock-lib.sh"
  cs_lock_path_mtime "$TMP/mtime-target"
)
code=$?
set -e
[ "$code" -ne 0 ] || fail "an all-garbage stat must be a failure, not a success"
[ -z "$out" ] || fail "a failed mtime read leaked output: '$out'"
pass "a non-numeric stat result is a clean failure, never passed downstream"

# And the real system stat still yields a pure-integer epoch mtime.
out=$(
  unset _CS_LOCK_STAT_FLAVOR CS_LOCK_LIB_SOURCED
  # shellcheck source=bin/cs-lock-lib.sh
  . "$ROOT/bin/cs-lock-lib.sh"
  cs_lock_path_mtime "$TMP/mtime-target"
) || fail "the real stat must read the fixture's mtime"
case "$out" in
  ''|*[!0-9]*) fail "the real stat did not yield a pure integer: '$out'" ;;
esac
pass "the real platform stat yields a pure-integer epoch mtime"
