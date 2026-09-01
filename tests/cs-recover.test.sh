#!/usr/bin/env bash
# Behavior (portable): bounded recovery re-wakes durable messages once and refuses stale endpoints.
set -u
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cs-recover.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
STATE="$HOME_DIR/state"
FAKEBIN="$TMP/fakebin"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/data" "$STATE/inbox" "$FAKEBIN"

# shellcheck source=bin/cs-message-lib.sh
. "$ROOT/bin/cs-message-lib.sh"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "pane get")
    printf '{"result":{"pane":{"cwd":"%s"}}}\n' "${CS_FAKE_PANE_CWD:?}"
    ;;
  "agent prompt")
    printf '%s\n' "${4:-}" >> "${CS_FAKE_PROMPTS:?}"
    printf '{"result":{"type":"agent_prompted"}}\n'
    ;;
  *) printf '{}\n' ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

cat > "$STATE/root.meta" <<EOF
task_id=root
kind=capo
home=$HOME_DIR
worktree=$HOME_DIR
pane=w-root:p1
endpoint_generation=root-generation
EOF
cat > "$STATE/child.meta" <<EOF
task_id=child
kind=ship
home=$HOME_DIR
worktree=$HOME_DIR
pane=w-child:p1
parent_task_id=root
parent_home=$HOME_DIR
parent_state=$STATE
parent_pane=w-root:p1
parent_generation=root-generation
endpoint_generation=child-generation
EOF

message_id=message-recover-0000000000000001
cs_message_publish "$STATE/inbox" \
  "schema=cs-message.v1" "message_id=$message_id" "correlation_id=$message_id" \
  "sequence=1" "kind=question" "from_task_id=child" "to_task_id=root" \
  "from_home=$HOME_DIR" "from_endpoint_generation=child-generation" \
  "to_endpoint_generation=root-generation" "summary=needs recovery" "artifact=" \
  "commit_sha=" "pull_request=" "created_at=1700000000" || fail "message setup"
cs_message_pending_create "$STATE" "$message_id" "$message_id" child root question 1700000000 || fail "pending setup"

export PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" CS_STATE_OVERRIDE="$STATE" \
  CS_HERDR_SESSION=test CS_FAKE_PANE_CWD="$HOME_DIR" CS_FAKE_PROMPTS="$TMP/prompts"
if output=$("$ROOT/bin/cs-recover.sh" 2>"$TMP/err"); then
  :
else
  fail "recover should re-wake a live durable message"
fi
printf '%s\n' "$output" | grep -F "re-woke message=$message_id" >/dev/null || fail "recover did not report the re-wake"
[ "$(grep -Fc "CONSIGLIERE_WAKE v1 message=$message_id" "$TMP/prompts")" = 1 ] || fail "recover did not deliver one bounded wake"
pass "recovery re-wakes an existing durable obligation once"

export CS_FAKE_PANE_CWD="$TMP/wrong-worktree"
if "$ROOT/bin/cs-recover.sh" >"$TMP/wrong.out" 2>"$TMP/wrong.err"; then
  fail "recover accepted a wrong-home endpoint"
fi
grep -F 'wrong' "$TMP/wrong.err" >/dev/null || fail "wrong-home recovery refusal lacked its reason"
[ "$(grep -Fc "CONSIGLIERE_WAKE v1 message=$message_id" "$TMP/prompts")" = 1 ] || fail "wrong-home recovery sent a wake"
pass "recovery refuses a stale or wrong-home endpoint without guessing"

pass "bounded durable-message recovery contract"
