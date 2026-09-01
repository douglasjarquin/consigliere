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
WORKTREE="$TMP/child-worktree"
FAKEBIN="$TMP/fakebin"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/data" "$STATE/inbox" "$WORKTREE/reports" "$FAKEBIN"

git -C "$WORKTREE" init -q || fail "child worktree setup"
git -C "$WORKTREE" config user.email test@example.invalid
git -C "$WORKTREE" config user.name test
printf '%s\n' 'verified artifact' > "$WORKTREE/reports/result.md"
git -C "$WORKTREE" add reports/result.md
git -C "$WORKTREE" commit -q -m 'add result artifact'
CHILD_COMMIT=$(git -C "$WORKTREE" rev-parse HEAD)

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
worktree=$WORKTREE
parent_task_id=current
parent_home=$HOME_DIR
parent_state=$STATE
parent_pane=unknown
parent_generation=current-generation
endpoint_generation=child-generation
harness=codex
EOF

message() {
  local id=$1 target=$2 kind=$3 generation=$4 artifact=${5:-reports/result.md} commit=${6:-$CHILD_COMMIT} pull_request=${7:-}
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
    "artifact=$artifact" \
    "commit_sha=$commit" \
    "pull_request=$pull_request" \
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

message message-invalid-result current result child-generation reports/missing.md || fail "invalid result setup"
if "$INBOX" --ack message-invalid-result >/dev/null 2>"$TMP/invalid-result.err"; then
  fail "a result with a missing artifact must not be acknowledged"
fi
grep -F 'artifact' "$TMP/invalid-result.err" >/dev/null || fail "invalid result refusal must name the artifact"
[ ! -e "$STATE/inbox/message-invalid-result.ack" ] || fail "invalid result was acknowledged"
pass "result acknowledgement refuses an unverifiable artifact"

message message-invalid-commit current result child-generation reports/result.md \
  0000000000000000000000000000000000000000 || fail "invalid commit setup"
if "$INBOX" --ack message-invalid-commit >/dev/null 2>"$TMP/invalid-commit.err"; then
  fail "a result with a missing commit must not be acknowledged"
fi
grep -F 'commit' "$TMP/invalid-commit.err" >/dev/null || fail "invalid commit refusal must name the commit"
[ ! -e "$STATE/inbox/message-invalid-commit.ack" ] || fail "invalid commit was acknowledged"
pass "result acknowledgement refuses an unverifiable commit"

mkdir -p "$TMP/outside"
printf '%s\n' 'outside artifact' > "$TMP/outside/result.md"
ln -s "$TMP/outside" "$WORKTREE/escape"
message message-invalid-symlink current result child-generation escape/result.md || fail "symlink artifact setup"
if "$INBOX" --ack message-invalid-symlink >/dev/null 2>"$TMP/invalid-symlink.err"; then
  fail "an artifact through a symlinked directory must not be acknowledged"
fi
grep -F 'escapes' "$TMP/invalid-symlink.err" >/dev/null || fail "symlink escape refusal must name the escape"
[ ! -e "$STATE/inbox/message-invalid-symlink.ack" ] || fail "symlink escape was acknowledged"
pass "result acknowledgement refuses a symlinked artifact directory"

cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  case "${FAKE_PR_MODE:-valid}" in
    valid) printf 'pr:\n  number: %s\n' "${3:-}"; exit 0 ;;
    mismatch) printf 'pr:\n  number: 99\n'; exit 0 ;;
    unavailable) exit 1 ;;
  esac
fi
exit 2
SH
chmod +x "$FAKEBIN/gh-axi"
message message-valid-pr current result child-generation reports/result.md "$CHILD_COMMIT" 42
if ! PATH="$FAKEBIN:$PATH" FAKE_PR_MODE=valid "$INBOX" --ack message-valid-pr >/dev/null; then
  fail "a result with a matching PR identity should be acknowledged"
fi
pass "result acknowledgement accepts a verifiable pull request"

message message-mismatched-pr current result child-generation reports/result.md "$CHILD_COMMIT" 43
if PATH="$FAKEBIN:$PATH" FAKE_PR_MODE=mismatch "$INBOX" --ack message-mismatched-pr >/dev/null 2>"$TMP/mismatched-pr.err"; then
  fail "a result with a mismatched PR identity must not be acknowledged"
fi
grep -F 'pull request identity' "$TMP/mismatched-pr.err" >/dev/null || fail "mismatched PR refusal must name the identity"
[ ! -e "$STATE/inbox/message-mismatched-pr.ack" ] || fail "mismatched PR was acknowledged"
pass "result acknowledgement refuses a mismatched pull request"

message message-unavailable-pr current result child-generation reports/result.md "$CHILD_COMMIT" 44
if PATH="$FAKEBIN:$PATH" FAKE_PR_MODE=unavailable "$INBOX" --ack message-unavailable-pr >/dev/null 2>"$TMP/unavailable-pr.err"; then
  fail "a result whose PR cannot be queried must not be acknowledged"
fi
grep -F 'pull request could not be verified' "$TMP/unavailable-pr.err" >/dev/null || fail "unavailable PR refusal must name verification"
[ ! -e "$STATE/inbox/message-unavailable-pr.ack" ] || fail "unavailable PR was acknowledged"
pass "result acknowledgement refuses an unavailable pull request"

printf '%s\n' 'home='"$TMP/other-home" >> "$STATE/child.meta"
if "$INBOX" --ack message-current >/dev/null 2>"$TMP/mismatched-home.err"; then
  fail "a message whose sender metadata home differs must not be acknowledged"
fi
grep -F 'metadata home' "$TMP/mismatched-home.err" >/dev/null || fail "sender home mismatch refusal must name the mismatch"
printf '%s\n' 'home='"$HOME_DIR" >> "$STATE/child.meta"
pass "inbox acknowledgement refuses a sender home mismatch"

mv "$STATE/inbox/message-current.msg" "$STATE/inbox/alias-current.msg"
if "$INBOX" >/dev/null 2>"$TMP/filename-mismatch.err"; then
  fail "a message filename that differs from its embedded identity must be refused"
fi
grep -F 'malformed' "$TMP/filename-mismatch.err" >/dev/null || fail "filename mismatch refusal must name the malformed record"
mv "$STATE/inbox/alias-current.msg" "$STATE/inbox/message-current.msg"
pass "inbox rejects a filename and embedded message identity mismatch"

message message-mismatched-pending current question child-generation
cs_message_pending_create "$STATE" message-mismatched-pending different-correlation child current question 1700000000 \
  || fail "mismatched pending setup"
if "$INBOX" --ack message-mismatched-pending --reply "answer" >/dev/null 2>"$TMP/mismatched-pending.err"; then
  fail "a response obligation with mismatched correlation must not be acknowledged"
fi
grep -F 'does not match' "$TMP/mismatched-pending.err" >/dev/null || fail "pending mismatch refusal must name the mismatch"
[ ! -e "$STATE/inbox/message-mismatched-pending.ack" ] || fail "mismatched pending obligation was acknowledged"
pass "response acknowledgement refuses a mismatched pending identity"

"$INBOX" --ack message-current >/dev/null || fail "message acknowledgement"
[ -f "$STATE/inbox/message-current.ack" ] || fail "acknowledgement record missing"
"$INBOX" --ack message-current >/dev/null || fail "duplicate acknowledgement"
if "$INBOX" --ack message-other >/dev/null 2>&1; then
  fail "a message addressed to another task must not be acknowledged"
fi
printf '%s\n' 'schema=cs-message.v1' 'message_id=message-other' 'acked_at=1700000000' \
  > "$STATE/inbox/message-current.ack"
if "$INBOX" --ack message-current >/dev/null 2>&1; then
  fail "an acknowledgement naming another message must not suppress the requested message"
fi
pass "acknowledgement is explicit, scoped, and idempotent"

printf '%s\n' 'current-generation' > "$STATE/.home-endpoint-generation"
{
  printf '%s\n' 'parent_task_id=root'
  printf '%s\n' 'parent_home='"$HOME_DIR"
  printf '%s\n' 'parent_state='"$STATE"
  printf '%s\n' 'parent_pane=unknown'
  printf '%s\n' 'parent_generation=current-generation'
} >> "$STATE/child.meta"
message message-root root result child-generation
mv "$STATE/.home-endpoint-generation" "$TMP/root-generation.saved"
if CS_TASK_ID=root "$INBOX" --ack message-root >/dev/null 2>&1; then
  fail "the root inbox must refuse messages when its endpoint generation is absent"
fi
mv "$TMP/root-generation.saved" "$STATE/.home-endpoint-generation"
if CS_TASK_ID=root "$INBOX" --ack message-root >/dev/null; then
  :
else
  fail "the root inbox must work without a synthetic root metadata record"
fi
[ -f "$STATE/inbox/message-root.ack" ] || fail "root inbox did not acknowledge its message"
pass "the root inbox handles messages without requiring root.meta"

printf '%s\n' 'schema=invalid' > "$STATE/inbox/malformed.msg"
if "$INBOX" >/dev/null 2>"$TMP/malformed.err"; then
  fail "malformed inbox records must fail loudly"
fi
grep -F 'malformed' "$TMP/malformed.err" >/dev/null || fail "malformed refusal must name the record"
pass "malformed inbox records fail loudly"

pass "parent-scoped inbox drain contract"
