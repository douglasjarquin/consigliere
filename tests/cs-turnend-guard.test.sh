#!/usr/bin/env bash
# Behavior: the push-based turn-end Stop-hook guard defers to the session that
# actually holds the home lock.
#
# The guard scopes to a PRIMARY checkout but that does not tell it whether THIS
# session is the supervisor. cs-session-start.sh already turns "another live
# consigliere session holds the fleet lock" into a read-only session; the guard
# must mirror that and step aside (exit 0) instead of nagging a secondary session
# to drive a fleet it does not own.
#
#   Case A (the bug): another live process holds the lock -> guard exits 0, prints
#     no block banner, even with in-flight work and no watcher.
#   Case B (regression guard for the real primary): lock free, stale, or held by
#     this session's own process tree -> guard still blocks (exit 2) when work is
#     in flight and no watcher is live.
#   Case C: away mode (.afk) -> still exits 0 (existing behavior, unchanged).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(cs_test_tmproot cs-turnend-guard)

# Widen the harness ancestry match so cs-lock.sh status recognizes the fake
# holders this test controls (a backgrounded sleep, and the test shell itself)
# as live "harness" processes - the same widening tests/cs-lock.test.sh uses.
GUARD_HARNESS_RE='sleep|bash|zsh|codex|claude'

BLOCK_BANNER='TURN WOULD END BLIND - SUPERVISION IS OFF'

# make_primary_home <name>: a genuine primary-scoped consigliere home with one
# in-flight task and no live watcher. A capo-home marker force-includes it so the
# fixture needs no real git checkout; AGENTS.md, bin/, and state/ satisfy the
# rest of cs_primary_scope_matches.
make_primary_home() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/bin" "$dir/state"
  printf 'testcapo\n' > "$dir/.cs-capo-home"
  printf '# fixture\n' > "$dir/AGENTS.md"
  cs_write_meta "$dir/state/task.meta" "window=consigliere:cs-task" "kind=ship"
  printf '%s\n' "$dir"
}

# run_guard <home>: feed the Stop payload and run the guard scoped to <home>.
# Echoes combined stdout+stderr; the caller reads $? for the exit code.
run_guard() {
  local home=$1
  printf '{"stop_hook_active":false}' | \
    CS_ROOT_OVERRIDE="$home" \
    CS_HOME="$home" \
    CS_GUARD_GRACE=999 \
    CS_LOCK_HARNESS_RE="$GUARD_HARNESS_RE" \
    "$ROOT/bin/cs-turnend-guard.sh" 2>&1
}

test_defers_when_another_live_session_holds_lock() {
  local home out rc holder
  home=$(make_primary_home foreign-holder)

  # A live process that is NOT in the guard's ancestry holds the lock.
  sleep 300 &
  holder=$!
  printf '%s\n' "$holder" > "$home/state/.lock"

  out=$(run_guard "$home")
  rc=$?

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  expect_code 0 "$rc" "guard must defer (exit 0) when another live session holds the lock"
  assert_not_contains "$out" "$BLOCK_BANNER" \
    "guard must not print the block banner when it is not the lock holder"
  pass "cs-turnend-guard: defers when another live session holds the home lock"
}

test_blocks_when_lock_free() {
  local home out rc
  home=$(make_primary_home free-lock)
  # No state/.lock at all -> lock is free -> the real primary must still block.

  out=$(run_guard "$home")
  rc=$?

  expect_code 2 "$rc" "guard must still block (exit 2) when the lock is free and work is in flight"
  assert_contains "$out" "$BLOCK_BANNER" \
    "guard must print the block banner for a genuine primary ending a turn blind"
  pass "cs-turnend-guard: still blocks the real primary when the lock is free"
}

test_blocks_when_lock_stale() {
  local home out rc
  home=$(make_primary_home stale-lock)
  # A dead holder (no such pid) is a stale lock, not another live session.
  printf '99999999\n' > "$home/state/.lock"

  out=$(run_guard "$home")
  rc=$?

  expect_code 2 "$rc" "guard must still block (exit 2) when the lock is stale"
  assert_contains "$out" "$BLOCK_BANNER" \
    "a stale lock must not disable the guard for the real primary"
  pass "cs-turnend-guard: still blocks the real primary when the lock is stale"
}

test_blocks_when_lock_held_by_own_session() {
  local home out rc
  home=$(make_primary_home own-holder)
  # $$ is the test shell, a genuine ancestor of the guard spawned below, so this
  # models a lock held by THIS session's own process tree. The guard must treat
  # it as its own and fall through to block, exactly as the real primary does.
  printf '%s\n' "$$" > "$home/state/.lock"

  out=$(run_guard "$home")
  rc=$?

  expect_code 2 "$rc" "guard must still block (exit 2) when it holds the lock itself"
  assert_contains "$out" "$BLOCK_BANNER" \
    "guard must not defer to itself when its own session holds the lock"
  pass "cs-turnend-guard: still blocks when this session holds the lock"
}

test_away_mode_still_exits_zero() {
  local home out rc
  home=$(make_primary_home afk-home)
  # Free lock so the away-mode short-circuit (not the lock defer) is what exits 0.
  touch "$home/state/.afk"

  out=$(run_guard "$home")
  rc=$?

  expect_code 0 "$rc" "away mode must still exit 0"
  assert_not_contains "$out" "$BLOCK_BANNER" \
    "away mode owns supervision; the guard must not print the block banner"
  pass "cs-turnend-guard: away mode still exits 0 (existing behavior unchanged)"
}

test_defers_when_another_live_session_holds_lock
test_blocks_when_lock_free
test_blocks_when_lock_stale
test_blocks_when_lock_held_by_own_session
test_away_mode_still_exits_zero
