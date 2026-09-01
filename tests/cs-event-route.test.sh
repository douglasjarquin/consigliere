#!/usr/bin/env bash
# shellcheck disable=SC2031 # cs-watch.sh intentionally initializes STATE when sourced in the route seam subshell.
# Behavior (portable): native pane events resolve through one exact parent edge.
set -u
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cs-event-route.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
HOME_DIR="$TMP/home"
mkdir -p "$STATE" "$HOME_DIR/state"

# shellcheck source=bin/cs-meta-lib.sh
. "$ROOT/bin/cs-meta-lib.sh"

cat > "$STATE/worker.meta" <<EOF
task_id=worker
kind=ship
workspace=workspace-1
pane=w1:p1
harness=codex
parent_task_id=mate
parent_home=$HOME_DIR
parent_state=$HOME_DIR/state
parent_pane=w2:p1
parent_generation=mate-generation
endpoint_generation=worker-generation
EOF

route=$(cs_meta_event_route "$STATE" w1:p1 workspace-1 codex) || fail "a valid event route was rejected"
expected=$'worker\tmate\t'"$HOME_DIR"$'\t'"$HOME_DIR/state"$'\tw2:p1\tmate-generation\tworker-generation'
[ "$route" = "$expected" ] ||
  fail "valid event route returned '$route'"
pass "a valid event resolves to its exact immediate parent edge"

sed -i.bak "s|parent_home=.*|parent_home=$TMP|; s|parent_state=.*|parent_state=$STATE|" "$STATE/worker.meta"
rm -f "$STATE/worker.meta.bak"
record=$(printf 'w1:p1\tworkspace-1\t\tblocked\tcodex')
if ! (
  cd "$ROOT" || exit 2
  CS_STATE_OVERRIDE="$STATE" . "$ROOT/bin/cs-watch.sh"
  cs_transition_validate_route "$STATE" "$record"
); then
  fail "the watcher rejected a valid metadata-backed event route"
fi
generation_record=$(printf 'w1:p1\tworkspace-1\t\tblocked\tcodex\tworker-generation')
if ! (
  cd "$ROOT" || exit 2
  CS_STATE_OVERRIDE="$STATE" . "$ROOT/bin/cs-watch.sh"
  cs_transition_validate_event_generation "$STATE" "$generation_record"
); then
  fail "the watcher rejected an event carrying the current endpoint generation"
fi
stale_generation_record=$(printf 'w1:p1\tworkspace-1\t\tblocked\tcodex\told-generation')
if (
  cd "$ROOT" || exit 2
  CS_STATE_OVERRIDE="$STATE" . "$ROOT/bin/cs-watch.sh"
  cs_transition_validate_event_generation "$STATE" "$stale_generation_record"
); then
  fail "the watcher accepted a stale endpoint generation from the event spool"
fi
pass "the watcher refuses stale native event generations"
bad_record=$(printf 'w1:p1\twrong-workspace\t\tblocked\tcodex')
if (
  cd "$ROOT" || exit 2
  CS_STATE_OVERRIDE="$STATE" . "$ROOT/bin/cs-watch.sh"
  cs_transition_validate_route "$STATE" "$bad_record"
); then
  fail "the watcher accepted a workspace-mismatched event route"
fi
pass "the watcher applies the exact route before event escalation"

if cs_meta_event_route "$STATE" w1:p1 wrong-workspace codex >/dev/null 2>&1; then
  fail "a workspace-mismatched event was accepted"
fi
if cs_meta_event_route "$STATE" w1:p1 workspace-1 claude >/dev/null 2>&1; then
  fail "an agent-mismatched event was accepted"
fi
pass "workspace and agent mismatches are refused"

cp "$STATE/worker.meta" "$STATE/worker-copy.meta"
if cs_meta_event_route "$STATE" w1:p1 workspace-1 codex >/dev/null 2>&1; then
  fail "two metadata records for one pane were accepted as an unambiguous route"
fi
pass "recycled or ambiguous pane ownership is refused"

rm -f "$STATE/worker-copy.meta"
sed -i.bak '/^parent_generation=/d' "$STATE/worker.meta"
rm -f "$STATE/worker.meta.bak"
if cs_meta_event_route "$STATE" w1:p1 workspace-1 codex >/dev/null 2>&1; then
  fail "an event with a missing parent generation was accepted"
fi
pass "a missing parent edge is refused"

pass "exact event-to-parent route contract"
