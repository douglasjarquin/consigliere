#!/usr/bin/env bash
# Behavior: cs-send.sh submit confirmation against native agent state PLUS the
# composer verdict (ported upstream fix, firstmate #2647), pinned hermetically
# with a fake herdr.
#
# Reproduces the false-swallow experience: herdr can leave agent_status idle
# for a whole landed claude turn, and can keep queued Enter text visible while
# busy, so a steer that actually landed was reported swallowed. These cases pin
# the fix: a cleared composer confirms a landed-but-idle steer, a busy target
# with the text still visible reports queued, an unreadable composer stops the
# Enter retries instead of firing them blind, and only a genuinely idle pane
# with the text still proven in its composer stays unconfirmed.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(cs_test_tmproot cs-send-submit-confirm)
SEND="$ROOT/bin/cs-send.sh"

# Fake herdr knobs (env):
#   FAKE_STATUS_SEQ_FILE  file of agent_status lines; each `agent get` pops one
#                         line, and the last line then repeats forever - so a
#                         pre-send idle baseline can be followed by a busy pane
#   CS_FAKE_HERDR_CAPTURE file whose bytes `pane read` prints (the composer)
#   CS_SEND_LOG           every run/send-text/send-keys call appends here
# `agent wait` always fails: every case here is one native state never
# confirmed, which is exactly the surface the composer fallback owns.
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
next_status() {
  local f=${FAKE_STATUS_SEQ_FILE:-} s=idle
  if [ -n "$f" ] && [ -s "$f" ]; then
    s=$(head -1 "$f")
    if [ "$(grep -c . "$f")" -gt 1 ]; then
      tail -n +2 "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
  fi
  printf '%s' "$s"
}
case "${1:-} ${2:-}" in
  "pane get") printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
  "agent get")
    printf '{"result":{"agent":{"agent":"claude","agent_status":"%s"}}}\n' "$(next_status)" ;;
  "agent wait") exit 1 ;;
  "pane read")
    if [ -n "${CS_FAKE_HERDR_CAPTURE:-}" ]; then cat "$CS_FAKE_HERDR_CAPTURE" 2>/dev/null; fi ;;
  "pane process-info")
    printf '{"result":{"process_info":{"shell_pid":100,"foreground_processes":[{"pid":200,"argv0":"claude"}]}}}\n' ;;
  "pane run")
    if [ -n "${CS_SEND_LOG:-}" ]; then printf 'run:%s\n' "${4:-}" >> "$CS_SEND_LOG"; fi
    echo '{}' ;;
  "pane send-text")
    if [ -n "${CS_SEND_LOG:-}" ]; then printf 'text:%s\n' "${4:-}" >> "$CS_SEND_LOG"; fi
    echo '{}' ;;
  "pane send-keys")
    if [ -n "${CS_SEND_LOG:-}" ]; then printf 'keys:%s\n' "${4:-}" >> "$CS_SEND_LOG"; fi
    echo '{}' ;;
  *) echo '{}' ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/herdr"
export PATH="$FAKEBIN:$PATH"

# The same real claude 2.1.227 composer bytes tests/cs-composer-lib.test.sh
# pins: an empty composer (cleared -> the steer landed) and one still holding
# the typed text (proven pending).
RULE=$(printf '\033[0m\033[38;2;136;136;136m%s\033[0m\r' \
  "$(printf '\342\224\200%.0s' $(seq 1 53))")
EMPTY_CAP="$TMP/empty.cap"
printf '%s\n\342\235\257\302\240\r\n%s\n' "$RULE" "$RULE" > "$EMPTY_CAP"
PENDING_CAP="$TMP/pending.cap"
printf '%s\n\342\235\257\302\240do the thing\r\n%s\n' "$RULE" "$RULE" > "$PENDING_CAP"
BLANK_CAP="$TMP/blank.cap"
: > "$BLANK_CAP"

# make_home <name> -> a home whose ship task "build" targets pane w1:p1.
make_home() {
  local home="$TMP/$1"
  mkdir -p "$home/state"
  cs_write_meta "$home/state/build.meta" \
    "workspace=w1" "pane=w1:p1" "kind=ship" "mode=no-mistakes" "yolo=off"
  printf '%s\n' "$home"
}

# run_send <home> <seq-file> <capture> <retries> <out> <err> -> exit status
run_send() {
  local home=$1 seq=$2 cap=$3 retries=$4 out=$5 err=$6 rc=0
  env CS_HOME="$home" CS_STATE_OVERRIDE="$home/state" CS_SEND_SETTLE=0 \
    CS_SEND_RETRIES="$retries" CS_SEND_LOG="$home/send.log" \
    FAKE_STATUS_SEQ_FILE="$seq" CS_FAKE_HERDR_CAPTURE="$cap" \
    "$SEND" build "do the thing" > "$out" 2> "$err" || rc=$?
  printf '%s' "$rc"
}

enter_count() {  # <home>
  grep -c '^keys:Enter$' "$1/send.log" 2>/dev/null || true
}

# 1. THE FALSE SWALLOW (regression): the turn landed but herdr kept
#    agent_status idle the whole time, so native confirmation never fires. The
#    cleared composer is the delivery proof; this must report submitted, not a
#    swallow, and must not fire a single blind Enter retry.
home=$(make_home landed-idle)
seq="$TMP/landed-idle.seq"; printf 'idle\n' > "$seq"
rc=$(run_send "$home" "$seq" "$EMPTY_CAP" 3 "$TMP/landed.out" "$TMP/landed.err")
expect_code 0 "$rc" "a landed-but-idle-reported steer must be confirmed, not reported swallowed"
assert_contains "$(cat "$TMP/landed.out")" "submitted" \
  "the cleared composer must report the steer submitted"
[ "$(enter_count "$home")" = 0 ] \
  || fail "a composer-confirmed delivery must not fire Enter retries: $(cat "$home/send.log")"
pass "cs-send: a landed steer whose native state stayed idle is confirmed by the cleared composer"

# 2. queued-while-busy: native never confirms, the text stays visible in the
#    composer, and after the retry budget the target reads busy - the queued
#    shape, not a swallow.
home=$(make_home queued-busy)
seq="$TMP/queued-busy.seq"; printf 'idle\nworking\n' > "$seq"
rc=$(run_send "$home" "$seq" "$PENDING_CAP" 1 "$TMP/queued.out" "$TMP/queued.err")
expect_code 0 "$rc" "a busy target keeping queued text visible must report queued, not swallowed"
assert_contains "$(cat "$TMP/queued.out")" "queued" \
  "the exhausted-retries busy target must report the steer queued"
pass "cs-send: queued Enter text visible on a busy target reports queued after the retry budget"

# 3. unreadable composer: native never confirms and the composer cannot be
#    read; Enter must not be retried blind, and the result is unconfirmed.
home=$(make_home unreadable)
seq="$TMP/unreadable.seq"; printf 'idle\n' > "$seq"
rc=$(run_send "$home" "$seq" "$BLANK_CAP" 3 "$TMP/unread.out" "$TMP/unread.err")
[ "$rc" != 0 ] || fail "an unreadable composer must leave the send unconfirmed"
assert_contains "$(cat "$TMP/unread.err")" "UNCONFIRMED" \
  "the unreadable-composer refusal must say the send is unconfirmed"
assert_contains "$(cat "$TMP/unread.err")" "refusing to retry Enter" \
  "the refusal must say Enter is not retried blind"
[ "$(enter_count "$home")" = 0 ] \
  || fail "no Enter may be retried against an unreadable composer: $(cat "$home/send.log")"
pass "cs-send: an unreadable composer stops the Enter retries and stays unconfirmed"

# 4. genuine swallow: the pane stays idle AND the text stays proven in the
#    composer through every retry - unconfirmed, with the full Enter budget
#    spent (Enter only, never retyped).
home=$(make_home swallowed)
seq="$TMP/swallowed.seq"; printf 'idle\n' > "$seq"
rc=$(run_send "$home" "$seq" "$PENDING_CAP" 2 "$TMP/swal.out" "$TMP/swal.err")
[ "$rc" != 0 ] || fail "an idle pane with a pending composer must stay unconfirmed"
assert_contains "$(cat "$TMP/swal.err")" "sits unsubmitted" \
  "the genuine-pending failure must say the text sits unsubmitted"
[ "$(enter_count "$home")" = 2 ] \
  || fail "the pending composer must spend the Enter budget: $(cat "$home/send.log")"
[ "$(grep -c '^run:' "$home/send.log")" = 1 ] \
  || fail "the text must be typed exactly once, never retyped: $(cat "$home/send.log")"
pass "cs-send: a genuinely idle pane with a pending composer is unconfirmed, Enter-only"

pass "cs-send submit-confirmation contract (native state plus composer verdict)"
