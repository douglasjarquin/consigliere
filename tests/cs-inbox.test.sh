#!/usr/bin/env bash
# Behavior (portable): parent-scoped durable message drain and acknowledgement.
set -u
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INBOX="$ROOT/bin/cs-inbox.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cs-inbox.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
STATE="$HOME_DIR/state"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/data" "$STATE/inbox"

# shellcheck source=bin/cs-message-lib.sh
. "$ROOT/bin/cs-message-lib.sh"

cat > "$STATE/current.meta" <<EOF
task_id=current
kind=capo
home=$HOME_DIR
parent_task_id=root
parent_home=$HOME_DIR
parent_state=$STATE
parent_pane=unknown
parent_generation=root-generation
endpoint_generation=current-generation
EOF
cat > "$STATE/child.meta" <<EOF
task_id=child
kind=ship
home=$HOME_DIR
parent_task_id=current
parent_home=$HOME_DIR
parent_state=$STATE
parent_pane=unknown
parent_generation=current-generation
endpoint_generation=child-generation
EOF

message() {
  local id=$1 target=$2 kind=$3 generation=$4
  cs_message_publish "$STATE/inbox" \
    "schema=cs-message.v1" \
    "message_id=$id" \
    "correlation_id=$id" \
    "sequence=1" \
    "kind=$kind" \
    "from_task_id=child" \
    "to_task_id=$target" \
    "from_home=$HOME_DIR" \
    "from_endpoint_generation=$generation" \
    "to_endpoint_generation=current-generation" \
    "summary=$kind summary" \
    "artifact=" \
    "commit_sha=" \
    "pull_request=" \
    "created_at=1700000000"
}

if [ ! -x "$INBOX" ]; then
  fail "the parent-scoped inbox drain command must exist"
fi

message message-current current result child-generation || fail "current message setup"
message message-other other result child-generation || fail "other message setup"
message message-stale current blocked old-generation || fail "stale message setup"

export CS_HOME="$HOME_DIR" CS_STATE_OVERRIDE="$STATE" CS_TASK_ID=current
if output=$("$INBOX" 2>"$TMP/err"); then
  fail "a stale sender generation must refuse the inbox drain"
fi
grep -F 'stale' "$TMP/err" >/dev/null || fail "stale generation refusal must name the stale route"
pass "stale sender generation refuses before acknowledgement"

rm -f "$STATE/inbox/message-stale.msg"
output=$("$INBOX") || fail "current inbox drain"
printf '%s\n' "$output" | grep -F 'message-current' >/dev/null || fail "current task message missing from drain"
if printf '%s\n' "$output" | grep -F 'message-other' >/dev/null; then
  fail "another task's message leaked into the current inbox drain"
fi
pass "inbox drain filters to the current task"

"$INBOX" --ack message-current >/dev/null || fail "message acknowledgement"
[ -f "$STATE/inbox/message-current.ack" ] || fail "acknowledgement record missing"
"$INBOX" --ack message-current >/dev/null || fail "duplicate acknowledgement"
if "$INBOX" --ack message-other >/dev/null 2>&1; then
  fail "a message addressed to another task must not be acknowledged"
fi
pass "acknowledgement is explicit, scoped, and idempotent"

printf '%s\n' 'schema=invalid' > "$STATE/inbox/malformed.msg"
if "$INBOX" >/dev/null 2>"$TMP/malformed.err"; then
  fail "malformed inbox records must fail loudly"
fi
grep -F 'malformed' "$TMP/malformed.err" >/dev/null || fail "malformed refusal must name the record"
pass "malformed inbox records fail loudly"

pass "parent-scoped inbox drain contract"
