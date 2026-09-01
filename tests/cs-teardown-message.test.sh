#!/usr/bin/env bash
# Behavior: teardown preserves a task while its durable parent message remains open.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/cs-message-lib.sh
. "$ROOT/bin/cs-message-lib.sh"

TMP=$(cs_test_tmproot cs-teardown-message)
export CS_DATA_OVERRIDE="$TMP/data"
export CS_STATE_OVERRIDE="$TMP/state"
export CS_CONFIG_OVERRIDE="$TMP/config"
export CS_HOST_OVERRIDE="$TMP/host"
mkdir -p "$TMP/data" "$TMP/state/inbox" "$TMP/config" "$TMP/host" "$TMP/fakebin"

cat > "$TMP/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "pane get")
    printf '%s\n' '{"error":{"code":"pane_not_found","message":"gone"}}' >&2
    exit 1
    ;;
  "pane close"|"workspace list"|"pane list")
    printf '%s\n' '{}'
    ;;
  *)
    printf '%s\n' '{}'
    ;;
esac
SH
cat > "$TMP/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cat > "$TMP/fakebin/made" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP/fakebin/herdr" "$TMP/fakebin/gh-axi" "$TMP/fakebin/made"
export PATH="$TMP/fakebin:$PATH"

project="$TMP/project"
worktree="$TMP/worktree"
cs_git_worktree "$project" "$worktree" cs/msg1
cs_write_meta "$TMP/state/root.meta" \
  task_id=root kind=capo home="$TMP" worktree="$TMP" pane=w99:p98 \
  endpoint_generation=root-generation
cs_write_meta "$TMP/state/msg1.meta" \
  task_id=msg1 kind=ship home="$TMP" worktree="$worktree" project="$project" \
  mode=made workspace=w99 pane=w99:p99 endpoint_generation=msg1-generation \
  parent_task_id=root parent_home="$TMP" parent_state="$TMP/state" \
  parent_pane=w99:p98 parent_generation=root-generation

message_id=message-teardown-0000000000000001
cs_message_publish "$TMP/state/inbox" \
  "schema=cs-message.v1" "message_id=$message_id" "correlation_id=$message_id" \
  "sequence=1" "kind=question" "from_task_id=msg1" "to_task_id=root" \
  "from_home=$TMP" "from_endpoint_generation=msg1-generation" \
  "to_endpoint_generation=root-generation" "summary=needs answer" "artifact=" \
  "commit_sha=" "pull_request=" "created_at=1700000000" || fail "message setup"
cs_message_pending_create "$TMP/state" "$message_id" "$message_id" msg1 root question 1700000000 \
  || fail "pending setup"

set +e
output=$("$ROOT/bin/cs-teardown.sh" msg1 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "teardown must refuse an unresolved message obligation"
assert_contains "$output" "message reconciliation" "refusal names message reconciliation"
assert_present "$worktree" "unresolved obligation preserves the worktree"
assert_present "$TMP/state/msg1.meta" "unresolved obligation preserves metadata"
assert_present "$TMP/state/pending/$message_id.pending" "unresolved obligation preserves the pending record"
pass "teardown refuses unresolved durable messages before cleanup"
