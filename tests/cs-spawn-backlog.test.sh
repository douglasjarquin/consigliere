#!/usr/bin/env bash
# Behavior: cs-spawn.sh --backlog-item folds the dispatch backlog transition
# into the spawn itself. A named item is moved to In flight through tasks-axi
# before the spawn reports success; a failed transition fails the dispatch
# loudly and removes the provisional record; a manual backend skips with a
# printed reminder; and no named item prints a move-it-yourself reminder.
# Hermetic: herdr and tasks-axi are faked.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/cs-spawn.sh"
TMP=$(cs_test_tmproot cs-spawn-backlog)
FAKEBIN=$(cs_fakebin "$TMP")
cs_git_identity
trap cs_test_cleanup EXIT

# Minimal fake herdr, mirroring tests/cs-spawn-lock.test.sh.
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
  "pane run") : ;;
  "agent get")
    printf '{"result":{"agent":{"agent":"codex","agent_status":"idle"}}}\n' ;;
  *) printf '{}\n' ;;
esac
SH
# Fake tasks-axi: satisfies the compatibility probes, logs every start/done
# call, and fails a mutation when CS_TEST_TASKS_FAIL=1.
cat > "$FAKEBIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version|-v|-V) echo "tasks-axi 9.9.9" ;;
  update) echo "usage: tasks-axi update <id> --archive-body" ;;
  mv) echo "usage: tasks-axi mv [<id>...] --to <dest>" ;;
  start|done)
    printf '%s\n' "$*" >> "${CS_TEST_TASKS_LOG:?}"
    if [ "${CS_TEST_TASKS_FAIL:-0}" = 1 ]; then
      echo "boom: backend write failed" >&2
      exit 1
    fi ;;
  *) : ;;
esac
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/tasks-axi"

HOME_DIR="$TMP/home"
STATE="$HOME_DIR/state"
CONFIG="$HOME_DIR/config"
TASKS_LOG="$TMP/tasks-axi.log"
mkdir -p "$HOME_DIR/data" "$CONFIG" "$STATE"
printf -- '- project [local-only] - fixture\n' > "$CONFIG/projects.md"
REPO="$TMP/project"
cs_git_init_commit "$REPO"

# run_spawn <id> [extra spawn args...] -> stdout+stderr; exit code preserved.
run_spawn() {
  local id=$1
  shift
  mkdir -p "$HOME_DIR/data/$id"
  printf 'implement the fixture\nDelivery contract: mode=local-only\n' > "$HOME_DIR/data/$id/brief.md"
  env PATH="$FAKEBIN:$PATH" CS_HARNESS_OVERRIDE=codex \
    CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$STATE" \
    CS_CONFIG_OVERRIDE="$CONFIG" CS_CLAUDE_JSON="$TMP/claude.json" \
    CS_TEST_TASKS_LOG="$TASKS_LOG" \
    CS_FAKE_SPAWN_WORKTREE="$TMP/wt-$id" \
    "$SPAWN" "$id" "$REPO" --mode local-only --yolo off "$@" 2>&1
}

# 1. --backlog-item moves the item to In flight before the spawn succeeds
: > "$TASKS_LOG"
out=$(run_spawn t-ok --backlog-item item-ok) || fail "spawn with --backlog-item failed: $out"
assert_contains "$out" "spawned t-ok" "spawn reports success"
assert_contains "$(cat "$TASKS_LOG")" "start item-ok --file $CONFIG/backlog.md" \
  "dispatch marked the backlog item in flight"
meta=$(cat "$STATE/t-ok.meta")
assert_contains "$meta" "backlog_item=item-ok" "meta records the backlog item"
pass "dispatch transition lands before success"

# 2. a failed backlog write fails the spawn loudly and removes the record
: > "$TASKS_LOG"
if out=$(CS_TEST_TASKS_FAIL=1 run_spawn t-fail --backlog-item item-fail); then
  fail "spawn must fail when the backlog transition fails"
fi
assert_contains "$out" "could not be moved to In flight" "failure names the transition"
assert_absent "$STATE/t-fail.meta" "provisional record removed on backlog failure"
pass "failed backlog write is a loud failed dispatch"

# 3. manual backend skips the transition with a printed reminder
: > "$TASKS_LOG"
printf 'manual\n' > "$CONFIG/backlog-backend.conf"
out=$(run_spawn t-manual --backlog-item item-manual) || fail "manual-backend spawn failed: $out"
assert_contains "$out" "by hand" "manual backend prints a hand-edit reminder"
assert_contains "$out" "spawned t-manual" "manual-backend spawn still succeeds"
[ -s "$TASKS_LOG" ] && fail "manual backend must not call tasks-axi"
rm -f "$CONFIG/backlog-backend.conf"
pass "manual backend skips with reminder"

# 4. no --backlog-item prints a move-it-yourself reminder
: > "$TASKS_LOG"
out=$(run_spawn t-none) || fail "spawn without --backlog-item failed: $out"
assert_contains "$out" "no --backlog-item was named" "reminder printed when no item is named"
[ -s "$TASKS_LOG" ] && fail "no item named must not call tasks-axi"
pass "no named item reminds instead of writing"

# 5. --backlog-item is refused on --capo
out=$(env PATH="$FAKEBIN:$PATH" CS_HARNESS_OVERRIDE=codex CS_HOME="$HOME_DIR" \
  CS_STATE_OVERRIDE="$STATE" CS_CONFIG_OVERRIDE="$CONFIG" CS_DATA_OVERRIDE="$HOME_DIR/data" \
  "$SPAWN" t-capo "$TMP/nohome" --capo --backlog-item item-capo 2>&1) \
  && fail "capo spawn with --backlog-item must refuse"
assert_contains "$out" "a capo is never a backlog item" "capo refusal names the rule"
pass "--backlog-item refused on --capo"

pass "cs-spawn backlog dispatch transition"
