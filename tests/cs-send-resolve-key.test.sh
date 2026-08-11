#!/usr/bin/env bash
# Behavior: cs-send.sh --resolve-key, the answerer-closes path, pinned
# hermetically with a fake herdr (no real agent).
#
# Reproduces the orphaned-decision experience: a soldier opens
# "needs-decision [key=api-shape]:", consigliere answers, and the soldier's next
# event is "working [key=impl]" in a different key namespace - so no matching
# resolved line ever lands and the answered decision stays in the open-decisions
# fold forever. --resolve-key closes it at answer time instead. These cases pin
# both halves: that the close happens exactly when an answer is delivered, and
# that every other path (a refused key, an unconfirmed send, a flagless send, a
# later working:/done: line) closes nothing.
set -u
# shellcheck source=tests/capo-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/capo-helpers.sh"
# shellcheck source=bin/cs-classify-lib.sh
. "$ROOT/bin/cs-classify-lib.sh"
# shellcheck source=bin/cs-line-cap-lib.sh
. "$ROOT/bin/cs-line-cap-lib.sh"

TMP=$(cs_test_tmproot cs-send-resolve-key)
mkdir -p "$TMP"

SEND="$ROOT/bin/cs-send.sh"
FAKEBIN=$(cs_fakebin "$TMP")
cs_capo_fake_herdr "$FAKEBIN"
export PATH="$FAKEBIN:$PATH"
export FAKE_AGENT=codex FAKE_AGENT_STATUS=idle FAKE_PANE_EXISTS=1

# setup_home <name> [status-lines...] -> a home whose ship task "build" carries
# the given status log (nothing when none are given).
setup_home() {
  local name=$1 home
  shift
  home="$TMP/$name-$RANDOM"
  mkdir -p "$home/state"
  cs_write_meta "$home/state/build.meta" \
    "workspace=w1" "pane=w1:p1" "kind=ship" "mode=no-mistakes" "yolo=off"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$home/state/build.status"
  fi
  printf '%s\n' "$home"
}

# run_send <home> <out> <err> -- <cs-send args...> -> cs-send's exit status.
run_send() {
  local home=$1 out=$2 err=$3 rc=0
  shift 3
  env CS_HOME="$home" CS_STATE_OVERRIDE="$home/state" CS_SEND_LOG="$out" CS_SEND_SETTLE=0 \
    "$SEND" "$@" > "$out.stdout" 2> "$err" || rc=$?
  printf '%s' "$rc"
}

# open_keys <home> -> the still-open decision keys, one per line, per the ONE
# authoritative fold (never a re-implementation of it inside the test).
open_keys() {
  local home=$1 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "${line%%	*}"
  done <<EOF
$(status_open_decisions "$home/state/build.status")
EOF
}

# 1. reproduce-then-fix: the answered decision closes at answer time, and the
#    worker's own next event in another key namespace never closes it.
home=$(setup_home close 'needs-decision [key=api-shape]: REST or RPC?')
log="$TMP/close.log"; err="$TMP/close.err"
assert_contains "$(open_keys "$home")" api-shape "the decision must start out open"
printf 'working [key=impl]: building the client\ndone: shipped\n' >> "$home/state/build.status"
assert_contains "$(open_keys "$home")" api-shape \
  "a working:/done: line in another key namespace must never close the decision"
rc=$(run_send "$home" "$log" "$err" build --resolve-key api-shape "go with REST")
expect_code 0 "$rc" "answering with --resolve-key should succeed"
assert_grep 'resolved [key=api-shape]: answered via cs-send: go with REST' \
  "$home/state/build.status" "the answer must append the closing resolved line"
assert_not_contains "$(open_keys "$home")" api-shape \
  "the answered decision must leave the open-decisions fold"
assert_contains "$(cat "$log")" "go with REST" "the answer text must still be delivered"
pass "cs-send: an answered keyed decision closes at answer time"

# 2. a key that is not currently open is refused BEFORE anything is sent
home=$(setup_home mistyped 'needs-decision [key=api-shape]: REST or RPC?')
log="$TMP/mistyped.log"; err="$TMP/mistyped.err"
rc=$(run_send "$home" "$log" "$err" build --resolve-key api-shpae "go with REST")
[ "$rc" != 0 ] || fail "a key that is not open must be refused"
assert_contains "$(cat "$err")" "no open decision or blocker with that key" \
  "the refusal must name the missing open decision"
assert_contains "$(cat "$err")" "nothing was sent" "the refusal must state nothing was sent"
[ ! -s "$log" ] || fail "a refused --resolve-key must deliver no text: $(cat "$log")"
assert_no_grep 'resolved [key=' "$home/state/build.status" "a refused send must close nothing"
assert_contains "$(open_keys "$home")" api-shape "the real decision must stay open"
pass "cs-send: a key that is not open is refused before the send and closes nothing"

# 3. an already-closed key is refused the same way (no double close)
home=$(setup_home already \
  'needs-decision [key=api-shape]: REST or RPC?' \
  'resolved [key=api-shape]: settled earlier')
log="$TMP/already.log"; err="$TMP/already.err"
rc=$(run_send "$home" "$log" "$err" build --resolve-key api-shape "go with REST")
[ "$rc" != 0 ] || fail "an already-closed key must be refused"
[ "$(grep -c 'resolved \[key=api-shape\]' "$home/state/build.status")" = 1 ] \
  || fail "an already-closed decision must not be closed twice"
pass "cs-send: an already-closed key cannot be closed a second time"

# 4. an unconfirmed send closes nothing
home=$(setup_home unconfirmed 'blocked [key=creds]: need the deploy token')
log="$TMP/unconfirmed.log"; err="$TMP/unconfirmed.err"
rc=0
env CS_HOME="$home" CS_STATE_OVERRIDE="$home/state" CS_SEND_LOG="$log" CS_SEND_SETTLE=0 \
  CS_SEND_RETRIES=0 FAKE_AGENT_WAIT_FAIL=1 \
  "$SEND" build --resolve-key creds "token is in 1Password" >/dev/null 2> "$err" || rc=$?
[ "$rc" != 0 ] || fail "an unconfirmed submit must exit non-zero"
assert_no_grep 'resolved [key=creds]' "$home/state/build.status" \
  "an unconfirmed send must never close a decision"
assert_contains "$(open_keys "$home")" creds "the blocker must stay open after an unconfirmed send"
pass "cs-send: an unconfirmed send closes nothing"

# 5. a send without the flag closes nothing at all
home=$(setup_home flagless 'needs-review [key=impl]: built the parser')
log="$TMP/flagless.log"; err="$TMP/flagless.err"
rc=$(run_send "$home" "$log" "$err" build "keep going")
expect_code 0 "$rc" "an ordinary steer should still succeed"
assert_no_grep 'resolved [key=' "$home/state/build.status" \
  "a send without --resolve-key must close nothing"
assert_contains "$(open_keys "$home")" impl "the review must stay open after a plain steer"
pass "cs-send: a send without the flag closes nothing"

# 6. the flag is repeatable and closes every named key in one answer
home=$(setup_home repeatable \
  'needs-decision [key=api-shape]: REST or RPC?' \
  'blocked [key=creds]: need the deploy token' \
  'needs-decision [key=untouched]: pick a name')
log="$TMP/repeatable.log"; err="$TMP/repeatable.err"
rc=$(run_send "$home" "$log" "$err" build \
  --resolve-key api-shape --resolve-key=creds "REST, and the token is in 1Password")
expect_code 0 "$rc" "a repeated --resolve-key should succeed"
keys=$(open_keys "$home")
assert_not_contains "$keys" api-shape "the first named key must close"
assert_not_contains "$keys" creds "the second named key must close"
assert_contains "$keys" untouched "an unnamed decision must stay open"
pass "cs-send: --resolve-key is repeatable and closes only the keys it names"

# 7. usage refusals: --key, an explicit pane target, an empty message, an invalid
#    key, and a duplicate key
home=$(setup_home usage 'needs-decision [key=api-shape]: REST or RPC?')
log="$TMP/usage.log"; err="$TMP/usage.err"
rc=$(run_send "$home" "$log" "$err" build --resolve-key api-shape --key Enter)
[ "$rc" != 0 ] || fail "--resolve-key with --key must be refused"
assert_contains "$(cat "$err")" "cannot accompany --key" "the --key refusal must say why"
rc=$(run_send "$home" "$log" "$err" build --key Enter --resolve-key api-shape)
[ "$rc" != 0 ] || fail "--resolve-key after --key must be refused, never silently ignored"
assert_contains "$(cat "$err")" "cannot accompany --key" "the trailing --key refusal must say why"
rc=$(run_send "$home" "$log" "$err" "w1:p1" --resolve-key api-shape "go with REST")
[ "$rc" != 0 ] || fail "--resolve-key with an explicit pane target must be refused"
assert_contains "$(cat "$err")" "no decision ledger here" \
  "the pane-target refusal must say the ledger is missing"
rc=$(run_send "$home" "$log" "$err" build --resolve-key api-shape "")
[ "$rc" != 0 ] || fail "--resolve-key with an empty message must be refused"
assert_contains "$(cat "$err")" "nonempty answer message" "the empty-answer refusal must say why"
rc=$(run_send "$home" "$log" "$err" build --resolve-key 'api shape' "go with REST")
[ "$rc" != 0 ] || fail "an invalid decision key must be refused"
assert_contains "$(cat "$err")" "is not a valid decision key" "the invalid-key refusal must say why"
rc=$(run_send "$home" "$log" "$err" build --resolve-key api-shape --resolve-key api-shape "REST")
[ "$rc" != 0 ] || fail "a duplicate --resolve-key must be refused"
assert_contains "$(cat "$err")" "duplicate --resolve-key" "the duplicate refusal must say why"
[ ! -s "$log" ] || fail "no usage refusal may deliver text: $(cat "$log")"
assert_contains "$(open_keys "$home")" api-shape "no usage refusal may close the decision"
pass "cs-send: --resolve-key refuses --key, pane targets, empty answers, and bad keys"

# 8. a delivered answer whose closing append fails exits nonzero and prints the
#    exact manual close command, so the decision resurfaces instead of vanishing
home=$(setup_home appendfail 'needs-decision [key=api-shape]: REST or RPC?')
log="$TMP/appendfail.log"; err="$TMP/appendfail.err"
chmod 444 "$home/state/build.status"
rc=$(run_send "$home" "$log" "$err" build --resolve-key api-shape "go with REST")
chmod 644 "$home/state/build.status"
[ "$rc" != 0 ] || fail "a failed closing append must exit non-zero"
assert_contains "$(cat "$err")" "could not be closed" "the append failure must be reported"
assert_contains "$(cat "$err")" \
  "echo 'resolved [key=api-shape]: <how it was answered>' >> $home/state/build.status" \
  "the append failure must print the exact manual close command"
assert_contains "$(cat "$err")" "do not resend the answer" \
  "the append failure must warn against resending a delivered answer"
assert_contains "$(cat "$log")" "go with REST" "the answer itself was still delivered"
assert_contains "$(open_keys "$home")" api-shape \
  "a decision whose close failed must stay open so it resurfaces"
pass "cs-send: a failed close reports the manual command and leaves the decision open"

# 9. an over-long answer is cut by the shared per-line cap, marker and all
home=$(setup_home longnote 'needs-decision [key=api-shape]: REST or RPC?')
log="$TMP/longnote.log"; err="$TMP/longnote.err"
answer="REST$(awk 'BEGIN { while (i++ < 200) printf " and-then-some" }')"
rc=$(run_send "$home" "$log" "$err" build --resolve-key api-shape "$answer")
expect_code 0 "$rc" "an over-long answer should still be delivered and closed"
line=$(grep -F 'resolved [key=api-shape]' "$home/state/build.status")
case "$line" in
  'resolved [key=api-shape]: answered via cs-send: REST and-then-some'*' [truncated]') : ;;
  *) fail "an over-long answer was not capped with its lede intact: $line" ;;
esac
[ "${#line}" -le "$CS_LINE_CAP_DEFAULT" ] \
  || fail "the closing line ran ${#line} characters past the ${CS_LINE_CAP_DEFAULT}-character cap"
assert_not_contains "$(open_keys "$home")" api-shape "a capped close must still close the decision"
pass "cs-send: an over-long answer is cut to the shared per-line cap"

# 10. a needs-review record closes the same way, and a mid-turn (queued) send
#     still counts as delivered for the close
home=$(setup_home queued 'needs-review [key=impl]: built the parser')
log="$TMP/queued.log"; err="$TMP/queued.err"
rc=0
env CS_HOME="$home" CS_STATE_OVERRIDE="$home/state" CS_SEND_LOG="$log" CS_SEND_SETTLE=0 \
  FAKE_AGENT_STATUS=busy \
  "$SEND" build --resolve-key impl "reviewed, run the pipeline" > "$TMP/queued.out" 2> "$err" || rc=$?
expect_code 0 "$rc" "a mid-turn steer should still succeed"
assert_contains "$(cat "$TMP/queued.out")" "queued" "the mid-turn path should report queued"
assert_grep 'resolved [key=impl]: answered via cs-send: reviewed, run the pipeline' \
  "$home/state/build.status" "a queued answer must close its decision too"
assert_not_contains "$(open_keys "$home")" impl "the review must leave the fold once answered"
pass "cs-send: a queued mid-turn answer closes its decision"

pass "cs-send --resolve-key answerer-closes contract"
