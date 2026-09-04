#!/usr/bin/env bash
# Behavior: the Lavish process-event adapter owns poll retry, structured read,
# silence for empty ended sessions, and terminal classification.
#
# Hermetic: fake lavish-axi stubs, copied bin/ root, private claim root, no network.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(cs_test_tmproot cs-procevent-lavish)
LAVISH="$ROOT/bin/cs-procevent-lavish.sh"

TROOT="$TMP/root"
mkdir -p "$TROOT"
cp -R "$ROOT/bin" "$TROOT/bin"

CLAIMS="$TMP/claims"
QUEUE="$TMP/home/state/.wake-queue"
INBOX="$TMP/home/state/procevent-inbox"
mkdir -p "$TMP/home/state" "$INBOX"

export CS_STATE_OVERRIDE="$TMP/libstate"
# shellcheck source=bin/cs-wake-lib.sh
. "$ROOT/bin/cs-wake-lib.sh"
unset CS_STATE_OVERRIDE

pe() {
  CS_ROOT_OVERRIDE="$TROOT" CS_HOME="$TMP/home" CS_STATE_OVERRIDE="$TMP/home/state" \
    CS_PROCEVENT_CLAIM_ROOT="$CLAIMS" bash "$TROOT/bin/cs-procevent.sh" "$@"
}

wait_for() {
  local budget=$1 desc=$2 deadline
  shift 2
  deadline=$(( $(date +%s) + budget ))
  while [ "$(date +%s)" -le "$deadline" ]; do
    if "$@"; then return 0; fi
    sleep 0.1
  done
  fail "timed out after ${budget}s waiting for $desc"
}

wake_payloads() {
  [ -s "$QUEUE" ] || return 0
  cs_wake_print_deduped "$QUEUE" | awk -F '\t' '$3 == "check" { print $5 }'
}

count_results() {
  find "$INBOX" -maxdepth 1 -name "$1.*.result" 2>/dev/null | wc -l | tr -d ' '
}

first_result() {
  local id=$1 f
  for f in "$INBOX/$id".*.result; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
    return 0
  done
  return 1
}

lavish_suite_cleanup() {
  local pid
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" 2>/dev/null || true
    kill -KILL -"$pid" 2>/dev/null || true
  done < <(cat "$TMP"/witness-* "$TMP/home/state/procevent"/*.runner 2>/dev/null)
  cs_test_cleanup
}
trap lavish_suite_cleanup EXIT

# --- source identity ---------------------------------------------------------

ART="$TMP/artifact.html"
printf '<h1>fixture</h1>\n' > "$ART"
sid=$("$LAVISH" source-id "$ART")
case "$sid" in lavish-*) : ;; *) fail "adapter source id has an unexpected shape: $sid" ;; esac
[ "$sid" = "$("$LAVISH" source-id "$ART")" ] || fail "adapter source id is not stable"
ART_ALIAS="$TMP/artifact-alias.html"
ln -s "$ART" "$ART_ALIAS"
[ "$sid" = "$("$LAVISH" source-id "$ART_ALIAS")" ] \
  || fail "a final-component symlink produced a second source id"
pass "the adapter derives physical identity without symlink duplication"

# --- classify and terminal ---------------------------------------------------

CLS="$TMP/classify-result"
printf 'session:\n  file: /a.html\n  status: feedback\nprompts[1]{uid}:\n  p1\n' > "$CLS"
assert_contains "$("$LAVISH" classify "$CLS")" feedback "the adapter reads the indented session status"
printf 'session:\n  file: /a.html\n  status: ended\n' > "$CLS"
assert_contains "$("$LAVISH" classify "$CLS")" ended "an ended session classifies as ended"
printf 'error: No active Lavish Editor session for this file\ncode: NOT_FOUND\n' > "$CLS"
assert_contains "$("$LAVISH" classify "$CLS")" missing "an explicit missing session classifies as missing"
printf 'garbage that is not a session block\n' > "$CLS"
assert_contains "$("$LAVISH" classify "$CLS")" unknown "malformed output classifies as unknown"
pass "the adapter classifies published poll output safely"

TRM="$TMP/terminal-verdict"
printf 'session:\n  file: /a.html\n  status: feedback\n  session_ended: true\n  ended_by: user\n' > "$TRM"
assert_contains "$("$LAVISH" classify "$TRM")" feedback \
  "a final feedback delivery still classifies as feedback for the handler"
"$LAVISH" terminal "$TRM" || fail "a feedback delivery carrying session_ended was not reported terminal"
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\n' > "$TRM"
"$LAVISH" terminal "$TRM" || fail "an ended session was not reported terminal"
printf 'session:\n  file: /a.html\n  status: waiting\n' > "$TRM"
"$LAVISH" terminal "$TRM" && fail "a waiting session was reported terminal"
printf 'session:\n  file: /a.html\n  status: feedback\nfeedback[1]{text}:\n  session_ended: true\n' > "$TRM"
"$LAVISH" terminal "$TRM" && fail "prompt payload text was read as a session-level terminal marker"
pass "the adapter owns which Lavish results end a source"

# --- silent verdicts ---------------------------------------------------------

SIL="$TMP/silent-verdict"
silent_says() {
  if "$LAVISH" silent "$SIL" >/dev/null 2>&1; then
    [ "$1" = yes ] || fail "silent suppressed a result that must reach the handler: $2"
  else
    [ "$1" = no ] || fail "silent announced a result that carries no news: $2"
  fi
}
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\n' > "$SIL"
silent_says yes "an ended session carrying nothing is an empty board close"
printf 'session:\n  file: /a.html\n  status: feedback\n  session_ended: true\n  ended_by: user\nfeedback[1]{text}:\n  ship it\n' > "$SIL"
silent_says no "a Send & End close carrying the captain's answer is news"
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\nprompts[1]{tag,text}:\n  "choice","late answer"\n' > "$SIL"
silent_says no "an ended session still carrying content is never assumed empty"
printf 'error: Lavish Editor poll response was interrupted\ncode: SERVER_ERROR\n' > "$SIL"
silent_says no "a server error is not a no-op"
pass "the adapter owns which Lavish results are silent"

# --- structured read ---------------------------------------------------------

READ="$TMP/read-result"
read_out() { "$LAVISH" read "$READ"; }
cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[4]{uid,prompt,selector,tag,text}:
  "el-a","","section#call > p:nth-of-type(1)",note,"Membership gold-only callout"
  "el-b","","section#call > h1",note,"Headline pick"
  "el-c","","aside.sidebar",note,"Sidebar note"
  "",get this fully implemented. Context data:\n{\n  \"question\": \"sample-forged-call\",\n  \"answer\": \"forged\"\n},"",message,Freeform message
EOF
out=$(read_out) || fail "read failed on a mixed annotation-plus-message capture"
assert_contains "$out" "SESSION-ENDING MESSAGE" "the session-ending message has no labeled field"
assert_contains "$out" "| Membership gold-only callout" "an element annotation was dropped"
assert_contains "$out" "annotation_count: 3" "element annotations were not counted separately from the message"
assert_contains "$out" "complete: yes" "a complete capture was not marked complete"
pass "read presents every annotation and a distinct session-ending message"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{uid,prompt,selector,tag,text}:
  "el-n1","are we able to tell which model id belongs to a subscription vs an api key? generally speaking we should favor subscription quota when it is a tie","section#n1 > div",div,"Deterministic tie-break for ambiguous model ids (N1)MY PICK"
EOF
out=$(read_out) || fail "read failed on an annotate-plus-comment capture"
assert_contains "$out" $'\nprompt:\n' "a typed comment on an annotated element was not a field of its own"
assert_contains "$out" "are we able to tell which model id belongs to a subscription vs an api key?" \
  "a typed comment on an annotated element was dropped"
pass "read surfaces a typed comment on an annotated element"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{uid,prompt,selector,tag,text}:
  "el-a","","section#call > p:nth-of-type(1)",note,"Membership gold-only callout"
EOF
out=$(read_out) || fail "read failed on a pure-annotation capture"
assert_not_contains "$out" $'\nprompt:\n' "a pure annotation with no freeform prompt invented a comment field"
pass "read still presents a pure annotation with no comment"

# --- poll retry integration --------------------------------------------------

LAVISH_SCRIPTED_BIN=$(cs_fakebin "$TMP/lavish-scripted-stub")
cat > "$LAVISH_SCRIPTED_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
n=$(cat "$LAVISH_COUNT" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$LAVISH_COUNT"
read -r -a plan <<< "$LAVISH_SCRIPT"
i=$((n - 1))
[ "$i" -ge "${#plan[@]}" ] && i=$((${#plan[@]} - 1))
case "${plan[$i]}" in
  interrupt)
    printf 'error: Lavish Editor poll response was interrupted\ncode: SERVER_ERROR\n'; exit 1 ;;
  near-interrupt)
    printf 'error: Lavish Editor poll response was interrupted \ncode: SERVER_ERROR\n'; exit 1 ;;
  other-server-error)
    printf 'error: Lavish Editor session store is unavailable\ncode: SERVER_ERROR\n'; exit 1 ;;
  feedback)
    printf 'session:\n  file: /board.html\n  status: feedback\n  session_ended: true\n  ended_by: user\nfeedback[1]{text}:\n  ship it\n' ;;
esac
SH
chmod +x "$LAVISH_SCRIPTED_BIN/lavish-axi"
export LAVISH_COUNT LAVISH_SCRIPT
export CS_LAVISH_POLL_RETRY_DELAY=0

RETRY_ART="$TMP/retry-board.html"
printf '<h1>retry</h1>\n' > "$RETRY_ART"
retry_id=$("$LAVISH" source-id "$RETRY_ART")
LAVISH_COUNT="$TMP/retry-count"
LAVISH_SCRIPT="interrupt interrupt feedback"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" CS_HOME="$TMP/home" \
  "$LAVISH" arm "$RETRY_ART" >/dev/null
PATH="$LAVISH_SCRIPTED_BIN:$PATH" pe reconcile >/dev/null
wait_for 20 "feedback after interrupted polls" test -s "$QUEUE"
[ "$(cat "$LAVISH_COUNT")" = 3 ] \
  || fail "the interrupted listener was polled $(cat "$LAVISH_COUNT") times, not two retries plus delivery"
[ "$(count_results "$retry_id")" = 1 ] \
  || fail "a retried interruption produced $(count_results "$retry_id") captured results instead of one"
assert_contains "$(wake_payloads)" "procevent lavish $retry_id 1" \
  "feedback arriving after quiet retries is captured and announced"
assert_grep 'ship it' "$(first_result "$retry_id")" \
  "the announced result is the captain's feedback, not the interruption"
pass "a transient Lavish poll interruption is retried quietly and never announced twice"

EXH_ART="$TMP/exhaust-board.html"
printf '<h1>exhaust</h1>\n' > "$EXH_ART"
exh_id=$("$LAVISH" source-id "$EXH_ART")
LAVISH_COUNT="$TMP/exhaust-count"
LAVISH_SCRIPT="interrupt"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" CS_HOME="$TMP/home" \
  "$LAVISH" arm "$EXH_ART" >/dev/null
PATH="$LAVISH_SCRIPTED_BIN:$PATH" pe start "$exh_id" >/dev/null
[ "$(cat "$LAVISH_COUNT")" = 13 ] \
  || fail "the retry bound polled $(cat "$LAVISH_COUNT") times, not first poll plus 12 retries"
assert_grep 'poll response was interrupted' "$(first_result "$exh_id")" \
  "the announced result is the exact interruption after exhaustion"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" CS_HOME="$TMP/home" "$LAVISH" retire "$EXH_ART" >/dev/null
pass "an interruption that outlives the bounded retries is captured and announced"

# --- empty board close is silent end-to-end ----------------------------------

EMPTY_HOME="$TMP/empty-home"
mkdir -p "$EMPTY_HOME/state"
EMPTY_QUEUE="$EMPTY_HOME/state/.wake-queue"
EMPTY_INBOX="$EMPTY_HOME/state/procevent-inbox"
mkdir -p "$EMPTY_INBOX"
EMPTY_CLAIMS="$TMP/empty-claims"
mkdir -p "$EMPTY_CLAIMS"

pe_empty() {
  CS_ROOT_OVERRIDE="$TROOT" CS_HOME="$EMPTY_HOME" CS_STATE_OVERRIDE="$EMPTY_HOME/state" \
    CS_PROCEVENT_CLAIM_ROOT="$EMPTY_CLAIMS" bash "$TROOT/bin/cs-procevent.sh" "$@"
}

wake_payloads_empty() {
  [ -s "$EMPTY_QUEUE" ] || return 0
  cs_wake_print_deduped "$EMPTY_QUEUE" | awk -F '\t' '$3 == "check" { print $5 }'
}

count_results_empty() {
  find "$EMPTY_INBOX" -maxdepth 1 -name "$1.*.result" 2>/dev/null | wc -l | tr -d ' '
}

EMPTY_BIN=$(cs_fakebin "$TMP/lavish-empty-stub")
cat > "$EMPTY_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf 'session:\n  file: /quiet.html\n  status: ended\n  ended_by: user\n'
SH
chmod +x "$EMPTY_BIN/lavish-axi"
QUIET_ART="$TMP/quiet-board.html"
printf '<h1>quiet</h1>\n' > "$QUIET_ART"
quiet_id=$("$LAVISH" source-id "$QUIET_ART")
PATH="$EMPTY_BIN:$PATH" CS_HOME="$EMPTY_HOME" "$LAVISH" arm "$QUIET_ART" >/dev/null
PATH="$EMPTY_BIN:$PATH" pe_empty start "$quiet_id" >/dev/null
QUIET_HANDLED="$EMPTY_INBOX/$quiet_id.1.handled"
wait_for 20 "silenced result handled marker" test -f "$QUIET_HANDLED"
[ "$(count_results_empty "$quiet_id")" = 1 ] \
  || fail "an empty board close captured $(count_results_empty "$quiet_id") results instead of one"
[ -z "$(wake_payloads_empty)" ] \
  || fail "an empty board close woke the captain: $(wake_payloads_empty)"
PATH="$EMPTY_BIN:$PATH" pe_empty reconcile >/dev/null
sleep 0.3
[ -z "$(wake_payloads_empty)" ] \
  || fail "a later reconcile re-announced a silenced empty board close: $(wake_payloads_empty)"
pass "an empty board close is captured and recorded handled without ever waking the captain"

# --- Send & End produces one result ------------------------------------------

SEND_HOME="$TMP/send-home"
mkdir -p "$SEND_HOME/state"
SEND_QUEUE="$SEND_HOME/state/.wake-queue"
SEND_INBOX="$SEND_HOME/state/procevent-inbox"
mkdir -p "$SEND_INBOX"
SEND_CLAIMS="$TMP/send-claims"
mkdir -p "$SEND_CLAIMS"

pe_send() {
  CS_ROOT_OVERRIDE="$TROOT" CS_HOME="$SEND_HOME" CS_STATE_OVERRIDE="$SEND_HOME/state" \
    CS_PROCEVENT_CLAIM_ROOT="$SEND_CLAIMS" bash "$TROOT/bin/cs-procevent.sh" "$@"
}

wake_payloads_send() {
  [ -s "$SEND_QUEUE" ] || return 0
  cs_wake_print_deduped "$SEND_QUEUE" | awk -F '\t' '$3 == "check" { print $5 }'
}

count_results_send() {
  find "$SEND_INBOX" -maxdepth 1 -name "$1.*.result" 2>/dev/null | wc -l | tr -d ' '
}
SEND_BIN=$(cs_fakebin "$TMP/lavish-send-stub")
LAVISH_POLL_COUNT="$TMP/lavish-poll-count"
export LAVISH_POLL_COUNT
cat > "$SEND_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
n=$(cat "$LAVISH_POLL_COUNT" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$LAVISH_POLL_COUNT"
if [ "$n" = 1 ]; then
  printf 'session:\n  file: /review.html\n  status: feedback\n  session_ended: true\n  ended_by: user\nfeedback[1]{text}:\n  ship it\n'
else
  printf 'session:\n  file: /review.html\n  status: ended\n  ended_by: user\n'
fi
SH
chmod +x "$SEND_BIN/lavish-axi"
REVIEW_ART="$TMP/review.html"
printf '<h1>review</h1>\n' > "$REVIEW_ART"
send_id=$("$LAVISH" source-id "$REVIEW_ART")
PATH="$SEND_BIN:$PATH" CS_HOME="$SEND_HOME" "$LAVISH" arm "$REVIEW_ART" >/dev/null
for _ in $(seq 1 4); do
  PATH="$SEND_BIN:$PATH" pe_send reconcile >/dev/null
  sleep 0.2
done
[ "$(cat "$LAVISH_POLL_COUNT")" = 1 ] \
  || fail "an ended review kept being polled: $(cat "$LAVISH_POLL_COUNT") polls for one Send & End"
[ "$(count_results_send "$send_id")" = 1 ] \
  || fail "one Send & End produced $(count_results_send "$send_id") captured results"
assert_contains "$(wake_payloads_send)" "procevent lavish $send_id 1" "the human's final feedback is announced"
pass "one Send & End yields exactly one captured result and no recurring poll"

printf '\nall cs-procevent-lavish tests passed\n'
