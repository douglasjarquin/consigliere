#!/usr/bin/env bash
# Behavior: cs-teardown.sh folds the completion backlog transition into the
# cleanup itself. A recorded backlog_item= is marked done through tasks-axi
# before the success line; a failed backlog write is a loud non-zero exit; a
# manual backend skips with a hand-edit reminder; and a task with no recorded
# item keeps the old record-completion reminder. Hermetic: herdr, gh, made,
# and tasks-axi are faked; the workspace is reported absent so teardown takes
# the git-worktree removal path.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$ROOT/bin/cs-meta-lib.sh"

TMP=$(cs_test_tmproot cs-teardown-backlog)
export CS_DATA_OVERRIDE="$TMP/data"
export CS_STATE_OVERRIDE="$TMP/state"
export CS_CONFIG_OVERRIDE="$TMP/config"
export CS_HOST_OVERRIDE="$TMP/host"
mkdir -p "$TMP/data" "$TMP/state" "$TMP/config" "$TMP/host"

FAKEBIN=$(cs_fakebin "$TMP")
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "workspace list") echo '{"result":{"workspaces":[]}}' ;;
  "pane list") echo '{"result":{"panes":[]}}' ;;
  "pane get")
    printf '{"error":{"code":"pane_not_found","message":"pane %s not found"}}\n' "$3" >&2; exit 1 ;;
  *) echo '{}' ;;
esac
exit 0
SH
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cp "$FAKEBIN/gh" "$FAKEBIN/gh-axi"
cat > "$FAKEBIN/made" <<'SH'
#!/usr/bin/env bash
exit 0
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
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/gh" "$FAKEBIN/gh-axi" "$FAKEBIN/made" "$FAKEBIN/tasks-axi"
export PATH="$FAKEBIN:$PATH"
TASKS_LOG="$TMP/tasks-axi.log"
export CS_TEST_TASKS_LOG="$TASKS_LOG"

cs_git_identity

BIN="$ROOT/bin/cs-teardown.sh"

# make_task <id> [meta extras...]: fixture repo + clean linked worktree + meta,
# mirroring tests/cs-teardown.test.sh's clean-teardown fixture shape.
make_task() {
  local id=$1 proj wt
  shift
  proj="$TMP/proj-$id"
  wt="$TMP/wt-$id"
  cs_git_init_commit "$proj"
  git -C "$proj" worktree add --quiet -b "cs/$id" "$wt"
  cs_write_meta "$TMP/state/$id.meta" \
    "workspace=w99" "pane=w99:p99" "worktree=$wt" "project=$proj" \
    "kind=ship" "mode=local-only" "yolo=off" "$@"
}

# 1. a recorded backlog_item is closed before the success line
: > "$TASKS_LOG"
make_task b1 "backlog_item=item-b1" "pr=https://github.com/o/r/pull/7"
out=$("$BIN" b1 2>&1) || fail "teardown with backlog item failed: $out"
assert_contains "$out" "teardown b1 complete" "teardown completes"
assert_contains "$out" "backlog item 'item-b1' recorded done" "success line names the closed item"
assert_contains "$(cat "$TASKS_LOG")" "done item-b1 --file $TMP/config/backlog.md --pr https://github.com/o/r/pull/7" \
  "completion transition landed with the PR attached"
pass "completion transition lands before success"

# 2. a failed backlog write is a loud non-clean result
: > "$TASKS_LOG"
make_task b2 "backlog_item=item-b2"
if out=$(CS_TEST_TASKS_FAIL=1 "$BIN" b2 2>&1); then
  fail "teardown must exit non-zero when the backlog close fails"
fi
assert_contains "$out" "still shows as in flight" "failure names the stranded item"
assert_absent "$TMP/state/b2.meta" "cleanup itself still happened"
pass "failed backlog write is a loud non-clean teardown"

# 3. manual backend skips the close with a hand-edit reminder
: > "$TASKS_LOG"
printf 'manual\n' > "$TMP/config/backlog-backend.conf"
make_task b3 "backlog_item=item-b3"
out=$("$BIN" b3 2>&1) || fail "manual-backend teardown failed: $out"
assert_contains "$out" "record completion of backlog item 'item-b3' by hand" \
  "manual backend prints a hand-edit reminder"
[ -s "$TASKS_LOG" ] && fail "manual backend must not call tasks-axi"
rm -f "$TMP/config/backlog-backend.conf"
pass "manual backend skips with reminder"

# 4. no recorded item keeps the old record-completion reminder
: > "$TASKS_LOG"
make_task b4
out=$("$BIN" b4 2>&1) || fail "teardown without backlog item failed: $out"
assert_contains "$out" "reminder: record completion in the backlog" \
  "old reminder printed when no item is recorded"
[ -s "$TASKS_LOG" ] && fail "no recorded item must not call tasks-axi"
pass "no recorded item reminds instead of writing"

pass "cs-teardown backlog completion transition"
