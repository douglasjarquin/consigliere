#!/usr/bin/env bash
# Behavior: capo_wake_stall_tick surfaces one durable parent check when a
# registered capo home's wake queue holds an unchanged row past the bound,
# without mutating the foreign queue or re-publishing the same row.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(cs_test_tmproot cs-capo-wake-stall)
HOME_DIR="$TMP/main"
CAPO="$TMP/capo"
mkdir -p "$HOME_DIR/state" "$CAPO/state"
printf 'qa-capo\n' > "$CAPO/.cs-capo-home"

export CS_ROOT_OVERRIDE="$TMP/fake-root"
mkdir -p "$CS_ROOT_OVERRIDE"
export CS_HOME="$HOME_DIR"
export CS_STATE_OVERRIDE="$HOME_DIR/state"
export CS_CAPO_WAKE_STALL_SECS=1

cs_write_meta "$HOME_DIR/state/qa-capo.meta" \
  "workspace=consigliere:qa-capo" \
  "pane=consigliere:qa-capo" \
  "kind=capo" \
  "mode=capo" \
  "home=$CAPO"

epoch=$(( $(date +%s) - 10 ))
row_before="$TMP/foreign-before"
printf '%s\t7\tcheck\trouted\tcheck: routed row\n' "$epoch" > "$CAPO/state/.wake-queue"
cp "$CAPO/state/.wake-queue" "$row_before"

# shellcheck source=bin/cs-watch.sh
. "$ROOT/bin/cs-watch.sh"
wake() { printf 'WAKE:%s\n' "$1"; return 0; }

out=$(capo_wake_stall_tick)
assert_contains "$out" 'check: capo wake-loop stalled: capo=qa-capo row=7' \
  "aged foreign row wakes the parent once"
assert_grep 'capo-wake-loop-qa-capo-' "$HOME_DIR/state/.wake-queue" \
  "stall notification is durable on the parent queue"
stall_count=$(grep -c 'capo-wake-loop-qa-capo-' "$HOME_DIR/state/.wake-queue" || true)
[ "$stall_count" -eq 1 ] || fail "expected exactly one stall notification, got $stall_count"
cmp -s "$row_before" "$CAPO/state/.wake-queue" \
  || fail "foreign queue changed during read-only stall detection"

out=$(capo_wake_stall_tick)
[ -z "$out" ] || fail "repeated tick re-published the stall: $out"
stall_count=$(grep -c 'capo-wake-loop-qa-capo-' "$HOME_DIR/state/.wake-queue" || true)
[ "$stall_count" -eq 1 ] || fail "repeated tick duplicated the stall notification"

: > "$CAPO/state/.wake-queue"
out=$(capo_wake_stall_tick)
[ -z "$out" ] || fail "empty foreign queue should stay quiet: $out"
assert_absent "$HOME_DIR/state/.capo-wake-stall-qa-capo" \
  "empty queue clears the stall marker"

printf '%s\t8\tcheck\thealthy\tcheck: healthy row\n' "$(date +%s)" > "$CAPO/state/.wake-queue"
CS_CAPO_WAKE_STALL_SECS=60
out=$(capo_wake_stall_tick)
[ -z "$out" ] || fail "young row should not stall yet: $out"

printf 'all cs-capo-wake-stall tests passed\n'
