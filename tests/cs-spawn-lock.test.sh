#!/usr/bin/env bash
# Behavior (portable): the cs-spawn.sh task-id lock is signal-safe and
# stale-recoverable. A lock left behind by a dead holder (dead recorded PID) is
# reclaimed so the spawn proceeds; a lock held by a genuinely live process still
# refuses; and a normal spawn releases its lock on exit. The critical safety
# property under test is that reclaim NEVER removes a live holder's lock.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$ROOT/bin/cs-meta-lib.sh"

SPAWN="$ROOT/bin/cs-spawn.sh"
TMP=$(cs_test_tmproot cs-spawn-lock)
FAKEBIN=$(cs_fakebin "$TMP")
cs_git_identity

# Kill any lingering live-holder stub and still run the registered dir cleanup.
LIVE_HOLDER=
_spawn_lock_cleanup() {
  [ -n "$LIVE_HOLDER" ] && kill "$LIVE_HOLDER" 2>/dev/null
  cs_test_cleanup
}
trap _spawn_lock_cleanup EXIT

# Minimal fake herdr: protocol check, worktree create (real git worktree so the
# isolation assertion passes), and pane run capture. Mirrors cs-spawn-harness.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "status --json") printf '%s\n' '{"server":{"protocol":16}}' ;;
  "worktree create")
    repo= branch=
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --cwd) repo=$2; shift ;;
        --branch) branch=$2; shift ;;
      esac
      shift
    done
    git -C "$repo" worktree add -q -b "$branch" "$CS_FAKE_SPAWN_WORKTREE"
    printf '{"result":{"workspace":{"workspace_id":"w1"},"root_pane":{"pane_id":"w1:p1"},"worktree":{"path":"%s","branch":"%s"}}}\n' "$CS_FAKE_SPAWN_WORKTREE" "$branch"
    ;;
  "pane run") printf '%s' "${4:-}" > "$CS_FAKE_SPAWN_LAUNCH" ;;
  "agent get")
    # cs-spawn requires an agent to actually appear after the launch: `pane run`
    # reports success even when a not-ready shell swallowed the line.
    printf '{"result":{"agent":{"agent":"codex","agent_status":"idle"}}}\n' ;;
  *) printf '{}\n' ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

HOME_DIR="$TMP/home"
STATE="$HOME_DIR/state"
mkdir -p "$HOME_DIR/data" "$STATE"
printf -- '- project [local-only] - fixture\n' > "$HOME_DIR/config/projects.md"
REPO="$TMP/project"
cs_git_init_commit "$REPO"

# run_spawn <id> -> runs a spawn for <id>, prints nothing, returns the exit code.
run_spawn() {
  local id=$1
  mkdir -p "$HOME_DIR/data/$id"
  # Every spawn here is a ship spawn, so the brief and the spawn state the same
  # explicit delivery contract (cs-spawn.sh cross-checks them).
  printf 'implement the fixture\nDelivery contract: mode=local-only\n' > "$HOME_DIR/data/$id/brief.md"
  env PATH="$FAKEBIN:$PATH" CS_HARNESS_OVERRIDE=codex \
    CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$STATE" \
    CS_CLAUDE_JSON="$TMP/claude.json" \
    CS_FAKE_SPAWN_WORKTREE="$TMP/wt-$id" CS_FAKE_SPAWN_LAUNCH="$TMP/launch-$id" \
    "$SPAWN" "$id" "$REPO" --mode local-only --yolo off >/dev/null 2>&1
}

# A reliably-dead PID: start a trivial process, reap it, so kill -0 fails.
sh -c 'exit 0' & DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true

# --- Case A: leaked lock with a dead owner is reclaimed ---------------------
ID_A=t-dead
mkdir -p "$STATE/.spawn-$ID_A.lock"
printf '%s\n' "$DEAD_PID" > "$STATE/.spawn-$ID_A.lock/pid"
run_spawn "$ID_A" || fail "case A: spawn refused a stale (dead-owner) lock instead of reclaiming"
assert_present "$STATE/$ID_A.meta" "case A: reclaimed spawn published metadata"
assert_absent "$STATE/.spawn-$ID_A.lock" "case A: reclaimed lock released on normal exit"
pass "case A: dead-owner lock reclaimed, spawn proceeds"

# --- Case B: lock held by a live owner still refuses ------------------------
# A real live process whose PID is recorded as the lock holder. The spawn must
# refuse and must NOT delete this live holder's lock.
sleep 300 & LIVE_HOLDER=$!
ID_B=t-live
mkdir -p "$STATE/.spawn-$ID_B.lock"
printf '%s\n' "$LIVE_HOLDER" > "$STATE/.spawn-$ID_B.lock/pid"
if run_spawn "$ID_B"; then
  fail "case B: spawn reclaimed a lock held by a LIVE process (false reclaim)"
fi
assert_absent "$STATE/$ID_B.meta" "case B: refused spawn published no metadata"
assert_present "$STATE/.spawn-$ID_B.lock/pid" "case B: live holder's lock left intact"
held=$(cat "$STATE/.spawn-$ID_B.lock/pid" 2>/dev/null || true)
[ "$held" = "$LIVE_HOLDER" ] || fail "case B: live holder's recorded PID was altered"
kill "$LIVE_HOLDER" 2>/dev/null; LIVE_HOLDER=
pass "case B: live-owner lock refuses, never reclaimed"

# --- Case C: normal spawn (no prior lock) acquires and releases -------------
ID_C=t-fresh
assert_absent "$STATE/.spawn-$ID_C.lock" "case C: no lock before spawn"
run_spawn "$ID_C" || fail "case C: normal spawn failed"
assert_present "$STATE/$ID_C.meta" "case C: normal spawn published metadata"
assert_absent "$STATE/.spawn-$ID_C.lock" "case C: lock released on normal exit"
pass "case C: normal spawn acquires and releases the lock"

pass "cs-spawn lock signal-safe and stale-recoverable"
