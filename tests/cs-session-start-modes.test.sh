#!/usr/bin/env bash
# tests/cs-session-start-modes.test.sh - issue #151 phase 3: the task-inventory
# cap, the --recover/--full modes, and the expanded-snapshot publish/prune
# mechanism cs-session-start.sh adds on top of its existing per-file/per-group
# bounds (already covered by tests/cs-session-start.test.sh, untouched here).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset CS_TASK_ID CS_ROOT_OVERRIDE CS_HOME CS_STATE_OVERRIDE CS_DATA_OVERRIDE

BIN="$ROOT/bin/cs-session-start.sh"
export CS_LOCK_HARNESS_RE='bash|zsh|codex|claude|sleep'

fresh_home() {
  local h
  h=$(cs_test_tmproot cs-session-start-modes)
  mkdir -p "$h/data" "$h/state" "$h/config"
  printf '%s\n' "$h"
}

seed_tasks() {  # <home> <count>
  local h=$1 n=$2 i
  for i in $(seq 1 "$n"); do
    cat > "$h/state/task$i.meta" <<EOF
workspace=w$i
pane=w$i:p1
worktree=/tmp/wt$i
project=/tmp/proj$i
kind=ship
mode=made
yolo=off
harness=codex
EOF
  done
}

# --- 1. the task-inventory cap discloses an exact remainder and a pointer ---
HOME1=$(fresh_home)
seed_tasks "$HOME1" 20
out=$(CS_HOME="$HOME1" CS_SESSION_START_TASK_LIMIT=5 "$BIN" 2>&1)
shown=$(printf '%s\n' "$out" | grep -c '^--- task')
[ "$shown" -eq 5 ] || fail "expected 5 task blocks shown with CS_SESSION_START_TASK_LIMIT=5, got $shown"
assert_contains "$out" "shown 5 of 20 task(s); 15 more" "the cap discloses the exact remainder"
assert_contains "$out" "CS_SESSION_START_TASK_LIMIT" "the remainder names the raising knob"
assert_contains "$out" "cs-fleet-view.sh" "the remainder points at the complete fleet review"
pass "the task-inventory cap shows an exact count and a targeted pointer for the rest"

# --- 2. --recover shows every task, publishes no snapshot -------------------
HOME2=$(fresh_home)
seed_tasks "$HOME2" 20
out=$(CS_HOME="$HOME2" CS_SESSION_START_TASK_LIMIT=5 "$BIN" --recover 2>&1)
shown=$(printf '%s\n' "$out" | grep -c '^--- task')
[ "$shown" -eq 20 ] || fail "--recover must show every task regardless of CS_SESSION_START_TASK_LIMIT, got $shown"
assert_contains "$out" "this run already shows the unbounded view" "--recover explains why it skips the snapshot"
assert_absent "$HOME2/data/session-start" "--recover must not publish a snapshot directory"
pass "--recover shows every task and skips the snapshot"

# --- 3. --full additionally lifts the status-tail and memory-byte caps -----
HOME3=$(fresh_home)
seed_tasks "$HOME3" 1
STATUS="$HOME3/state/task1.status"
i=0
while [ "$i" -lt 20 ]; do
  printf 'note: line %s of a long status log\n' "$i" >> "$STATUS"
  i=$((i + 1))
done
big=$(printf '%s' "the boss prefers plain outcome language, repeated many times over. ")
: > "$HOME3/config/learnings.md"
i=0
while [ "$i" -lt 200 ]; do
  printf '%s\n' "$big" >> "$HOME3/config/learnings.md"
  i=$((i + 1))
done
size=$(wc -c < "$HOME3/config/learnings.md" | tr -d '[:space:]')
[ "$size" -gt 8192 ] || fail "fixture learnings.md must exceed the default 8192-byte budget to test the lift"

out_normal=$(CS_HOME="$HOME3" "$BIN" 2>&1)
lines_normal=$(printf '%s\n' "$out_normal" | grep -c '^note: line')
[ "$lines_normal" -lt 20 ] || fail "normal mode must still cap the status tail (got all $lines_normal lines)"
assert_contains "$out_normal" "OVER STARTUP-MEMORY BUDGET" "normal mode still reports the oversized memory file"

out_recover=$(CS_HOME="$HOME3" "$BIN" --recover 2>&1)
lines_recover=$(printf '%s\n' "$out_recover" | grep -c '^note: line')
[ "$lines_recover" -lt 20 ] || fail "--recover must still cap the per-task status tail (got all $lines_recover lines)"
assert_contains "$out_recover" "OVER STARTUP-MEMORY BUDGET" "--recover still reports the oversized memory file (byte cap stays)"

out_full=$(CS_HOME="$HOME3" "$BIN" --full 2>&1)
lines_full=$(printf '%s\n' "$out_full" | grep -c '^note: line')
[ "$lines_full" -eq 20 ] || fail "--full must show every status-tail line, got $lines_full of 20"
assert_not_contains "$out_full" "OVER STARTUP-MEMORY BUDGET" "--full lifts the memory-byte cap, so no over-budget report fires"
pass "--full lifts the status-tail and memory-byte caps that --recover deliberately keeps"

# --- 4. --recover and --full are mutually exclusive -------------------------
out=$(CS_HOME="$(fresh_home)" "$BIN" --recover --full 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "--recover and --full together must be refused"
assert_contains "$out" "mutually exclusive" "the refusal names the conflict"
pass "--recover and --full together are refused"

# --- 5. normal mode publishes the expanded snapshot, hash matches the file --
HOME5=$(fresh_home)
seed_tasks "$HOME5" 20
out=$(CS_HOME="$HOME5" CS_SESSION_START_TASK_LIMIT=5 "$BIN" 2>&1)
SNAP=$(printf '%s\n' "$out" | sed -n 's/^published: \(.*\) (sha256 .*/\1/p')
[ -n "$SNAP" ] && [ -f "$SNAP" ] || fail "normal mode must publish a snapshot file (got '$SNAP')"
REPORTED=$(printf '%s\n' "$out" | sed -n 's/.*sha256 \([0-9a-f]*\)).*/\1/p')
ACTUAL=$( (shasum -a 256 "$SNAP" 2>/dev/null || sha256sum "$SNAP" 2>/dev/null) | awk '{print $1}')
[ "$REPORTED" = "$ACTUAL" ] || fail "the reported sha256 ($REPORTED) does not match the published file's actual hash ($ACTUAL)"
snap_shown=$(grep -c '^--- task' "$SNAP")
[ "$snap_shown" -eq 20 ] || fail "the snapshot itself must hold every task unbounded, got $snap_shown of 20"
case "$SNAP" in "$HOME5"/data/session-start/*) : ;; *) fail "the snapshot must live under this home's own data/session-start/, got $SNAP" ;; esac
pass "normal mode publishes a snapshot whose hash matches its bytes and whose content is unbounded"

# --- 6. retention prunes to the configured keep count -----------------------
HOME6=$(fresh_home)
mkdir -p "$HOME6/data/session-start"
n=1
while [ "$n" -le 25 ]; do
  printf 'old\n' > "$HOME6/data/session-start/$(printf '2020%04dT000000Z' "$n")-home.md"
  n=$((n + 1))
done
CS_HOME="$HOME6" CS_SESSION_START_SNAPSHOT_KEEP=5 "$BIN" >/dev/null 2>&1
# shellcheck disable=SC2012  # filenames are our own timestamp-prefixed stamps, never adversarial or containing newlines
kept=$(ls "$HOME6/data/session-start" | wc -l | tr -d '[:space:]')
[ "$kept" -eq 5 ] || fail "expected exactly 5 snapshots retained with CS_SESSION_START_SNAPSHOT_KEEP=5, got $kept"
pass "snapshot retention prunes down to the configured keep count"

# --- 7. a read-only (lock-refused) session publishes nothing ---------------
HOME7=$(fresh_home)
seed_tasks "$HOME7" 5
sleep 300 &
HOLDER=$!
trap 'kill "$HOLDER" 2>/dev/null' EXIT
printf '%s\n' "$HOLDER" > "$HOME7/state/.lock"
out=$(CS_HOME="$HOME7" "$BIN" 2>&1)
kill "$HOLDER" 2>/dev/null
assert_contains "$out" "another live consigliere session holds the lock" "the fixture actually produced a read-only session"
assert_contains "$out" "skipped (read-only session)" "a read-only session skips the snapshot publish"
assert_absent "$HOME7/data/session-start" "a read-only session must not create the snapshot directory"
pass "a read-only session never publishes a snapshot"

pass "cs-session-start.sh modes (--recover, --full, task cap, expanded snapshot)"
