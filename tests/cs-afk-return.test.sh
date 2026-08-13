#!/usr/bin/env bash
# tests/cs-afk-return.test.sh - bin/cs-afk-return.sh: the deterministic
# away-mode return catch-up gate.
#
# Behavioral contract covered:
#   - a buffered escalation left in state/.subsuper-escalations (the durable
#     delivery-cache path a real bin/cs-daemon.sh instance, or a pre-upgrade
#     away session, could still have populated) is flushed as durable
#     catch-up evidence and cleared;
#   - an open blocked: decision fails the return closed until it resolves.
#
# Fully offline: a fake herdr CLI answers what bin/cs-wake-drain.sh needs for
# an otherwise-empty queue; no real agent, no network.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/capo-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/capo-helpers.sh"

AFK_RETURN="$ROOT/bin/cs-afk-return.sh"
TMP_ROOT=$(cs_test_tmproot cs-afk-return)

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"; fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cs_capo_fake_herdr "$fakebin"
  printf '%s\n' "$dir"
}

# --- a buffered escalation survives to become catch-up evidence -------------

test_buffered_escalation_flushed_as_catchup_evidence() {
  local dir state fakebin out rc
  dir=$(make_case buffered-escalation); state="$dir/state"; fakebin="$dir/fakebin"
  date '+%s' > "$state/.afk"
  # Stands in for what a real bin/cs-daemon.sh instance (or a pre-upgrade away
  # session) could still leave behind: this file's own writer no longer exists
  # in the shipped launch path, but cs-afk-return.sh must still surface
  # whatever is actually sitting in it rather than assume it is always empty.
  printf 'done: PR https://example.test/pr/11\n' > "$state/.subsuper-escalations"

  out=$(env PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" "$AFK_RETURN" 2>&1)
  rc=$?
  expect_code 0 "$rc" "cs-afk-return with no open blockers"
  assert_contains "$out" "catch-up escalation:" "return did not flush the buffered escalation as evidence"
  assert_contains "$out" "done: PR https://example.test/pr/11" "return catch-up lost the escalation content"
  assert_contains "$out" "catch-up clear" "return did not report the gate clear"
  assert_absent "$state/.afk" "return did not clear state/.afk"
  assert_absent "$state/.subsuper-escalations" "return did not clear the delivery artifacts after surfacing them"
  assert_absent "$state/.afk-return-catchup" "return left its gate behind after a clean catch-up"
  pass "a buffered escalation left in state/.subsuper-escalations is flushed by cs-afk-return as catch-up evidence, which clears .afk"
}

# --- an open blocked: decision keeps the return gate closed -----------------

test_return_gate_blocks_on_open_blocker() {
  local dir state fakebin out rc
  dir=$(make_case return-blocked); state="$dir/state"; fakebin="$dir/fakebin"
  date '+%s' > "$state/.afk"
  cs_write_meta "$state/stuck.meta" "pane=w4:p4" "kind=ship"
  printf 'blocked [key=creds]: need the deploy token\n' > "$state/stuck.status"
  out=$(env PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" "$AFK_RETURN" 2>&1)
  rc=$?
  expect_code 3 "$rc" "cs-afk-return with a live open blocker"
  assert_contains "$out" "consigliere-actionable blocker: stuck [key=creds]" "gate did not name the open blocker"
  assert_present "$state/.afk-return-catchup" "the fail-closed gate file is missing"
  out=$(env PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" "$AFK_RETURN" guard 2>&1)
  rc=$?
  expect_code 3 "$rc" "guard while catch-up is pending"
  # Remediate: close the keyed decision, then check clears the gate.
  printf 'resolved [key=creds]: token installed\n' >> "$state/stuck.status"
  out=$(env PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" "$AFK_RETURN" check 2>&1)
  rc=$?
  expect_code 0 "$rc" "cs-afk-return check after the blocker resolved"
  assert_absent "$state/.afk-return-catchup" "check did not clear the gate after resolution"
  pass "the return catch-up gate fails closed on an open blocked: decision and clears only after resolved [key=...]"
}

test_buffered_escalation_flushed_as_catchup_evidence
test_return_gate_blocks_on_open_blocker

pass "cs-afk-return.sh return catch-up gate contract"
