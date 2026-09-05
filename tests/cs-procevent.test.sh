#!/usr/bin/env bash
# Behavior: the process-event runner drives a real BLOCKING fixture source end to
# end and holds its durability contract.
#
# Covered:
#   A - capture before publish; the wake carries identity only; a captured result
#       survives a simulated drain; `handled` is idempotent and refuses without
#       matching records; an acknowledged result stops being re-announced.
#   B - one DISTINCT wake per captured result.
#   C - the leader-crash cut: SIGKILL only the runner leader, prove its blocking
#       child's process group survives, reconcile, prove the old group is gone and
#       no second poller ever ran alongside it.
#   D - adapter-owned terminal retirement.
#   E - an adapter with no `terminal` command keeps its source armed.
#   F - capo-home retirement refuses while the home owns a claim it cannot release.
#   G - an armed source alone keeps supervision required in both guards.
#
# Hermetic: a copied bin/ root, a fixture adapter, a fixture blocking script, a
# private claim root, and a fake herdr. No network, no real herdr, no lavish-axi.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(cs_test_tmproot cs-procevent)

# Lock helpers for the capture-before-publish proof, plus cs_pid_identity for the
# hand-built claim in F. Point the library's own state at scratch so sourcing it
# never touches the repo checkout.
export CS_STATE_OVERRIDE="$TMP/libstate"
# shellcheck source=bin/cs-wake-lib.sh
. "$ROOT/bin/cs-wake-lib.sh"
unset CS_STATE_OVERRIDE

# A copied code root, because the runner requires an adapter to be a real
# non-symlink file under <root>/bin and this suite ships fixture adapters.
TROOT="$TMP/root"
mkdir -p "$TROOT"
cp -R "$ROOT/bin" "$TROOT/bin"

CLAIMS="$TMP/claims"
H1="$TMP/home1"
mkdir -p "$H1/state"
QUEUE="$H1/state/.wake-queue"
REG="$H1/state/procevent"
INBOX="$H1/state/procevent-inbox"

# --- fixtures ----------------------------------------------------------------

# An adapter whose ONLY runner-facing command is `terminal`, exactly the generic
# contract: exit 0 retires the source, anything else keeps it armed.
cat > "$TROOT/bin/cs-procevent-fixture.sh" <<'SH'
#!/usr/bin/env bash
set -u
case "${1-}" in
  terminal)
    grep -q '^TERMINAL$' "${2-}" 2>/dev/null && exit 0
    exit 1
    ;;
esac
exit 2
SH

# An adapter with NO terminal command at all: every call is an error, which must
# leave its source armed unchanged.
cat > "$TROOT/bin/cs-procevent-noterm.sh" <<'SH'
#!/usr/bin/env bash
printf 'error: unknown command: %s\n' "${1-}" >&2
exit 1
SH

# The blocking source: records its own pid so a test can prove exactly how many
# pollers ever ran and which are still alive, then blocks until <trigger> exists.
cat > "$TMP/blocker.sh" <<'SH'
#!/usr/bin/env bash
# <trigger> <payload> <witness>
set -u
printf '%s\n' "$$" >> "$3"
while [ ! -e "$1" ]; do sleep 0.05; done
cat "$2"
SH

# A non-blocking source, for the cases that only need a completed result.
cat > "$TMP/fast.sh" <<'SH'
#!/usr/bin/env bash
set -u
cat "$1"
SH

chmod +x "$TROOT/bin/cs-procevent-fixture.sh" "$TROOT/bin/cs-procevent-noterm.sh" \
  "$TMP/blocker.sh" "$TMP/fast.sh"

# --- harness -----------------------------------------------------------------

pe() {  # run the runner against home1
  CS_ROOT_OVERRIDE="$TROOT" CS_HOME="$H1" CS_STATE_OVERRIDE="$H1/state" \
    CS_PROCEVENT_CLAIM_ROOT="$CLAIMS" bash "$TROOT/bin/cs-procevent.sh" "$@"
}

wait_for() {  # <seconds> <description> <command...>
  local budget=$1 desc=$2 deadline
  shift 2
  deadline=$(( $(date +%s) + budget ))
  while [ "$(date +%s)" -le "$deadline" ]; do
    if "$@"; then return 0; fi
    sleep 0.1
  done
  fail "timed out after ${budget}s waiting for $desc"
}

poller_count() {  # how many pollers have ever started against a witness file
  [ "$(wc -l < "$1" | tr -d ' ')" = "$2" ]
}

queue_keys() {  # distinct procevent wake keys currently on the durable queue
  [ -s "$QUEUE" ] || return 0
  cs_wake_print_deduped "$QUEUE" | awk -F '\t' '$3 == "check" && $4 ~ /^procevent:/ { print $4 }'
}

# Kill anything the fixtures left running before the temp root disappears.
procevent_suite_cleanup() {
  local pid
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" 2>/dev/null || true
    kill -KILL -"$pid" 2>/dev/null || true
  done < <(cat "$TMP"/witness-* "$REG"/*.runner 2>/dev/null)
  cs_test_cleanup
}
trap procevent_suite_cleanup EXIT

# --- A: capture before publish, re-announcement, handled ---------------------

WITNESS_A="$TMP/witness-a"
: > "$WITNESS_A"
printf 'hello world\nsecond line\n' > "$TMP/payload-a"
pe register fixture srcA -- "$TMP/blocker.sh" "$TMP/trigger-a" "$TMP/payload-a" "$WITNESS_A" >/dev/null \
  || fail "A: register failed"

pe reconcile >/dev/null || fail "A: reconcile failed"
wait_for 20 "A's runner to claim the source" test -f "$CLAIMS/srcA.claim"
wait_for 20 "A's blocking child to start" test -s "$WITNESS_A"

# Hold the per-source lock the publisher must take. Capture happens BEFORE that
# lock is needed, so this freezes the runner exactly between the two steps.
cs_lock_acquire_wait "$CLAIMS/srcA.lock"
: > "$TMP/trigger-a"
wait_for 20 "A's result to be durably captured" test -f "$INBOX/srcA.1.result"
sleep 1
[ ! -s "$QUEUE" ] || fail "A: a wake referenced the result before capture committed:
$(cat "$QUEUE")"
[ "$(cat "$INBOX/srcA.1.adapter")" = fixture ] || fail "A: adapter identity was not captured"
pass "cs-procevent: a result is durably captured before any wake references it"

cs_lock_release "$CLAIMS/srcA.lock"
wait_for 20 "A's wake to reach the durable queue" test -s "$QUEUE"
assert_grep "procevent fixture srcA 1" "$QUEUE" "A: wake line must name adapter, source, and sequence"
assert_no_grep "hello world" "$QUEUE" "A: the wake must carry identity only, never source output"
pass "cs-procevent: the published wake carries identity only, never captured output"

pe retire srcA >/dev/null || fail "A: retire failed"
[ ! -e "$REG/srcA.source" ] || fail "A: retire left the registration in place"

: > "$QUEUE"   # simulate a drain
pe reconcile >/dev/null || fail "A: reconcile after drain failed"
assert_grep "procevent fixture srcA 1" "$QUEUE" \
  "A: an unacknowledged result must be re-announced after a drain"
pass "cs-procevent: an unacknowledged result survives a drain and is re-announced"

OUT=$(pe handled srcA 99 2>&1); RC=$?
expect_code 1 "$RC" "A: handled must refuse a sequence with no captured result"
assert_contains "$OUT" "no captured result to acknowledge" \
  "A: handled must say why it refused"
[ ! -e "$INBOX/srcA.99.handled" ] || fail "A: a refused handled must leave no marker"
pass "cs-procevent: handled refuses without a matching result and adapter record"

OUT=$(pe handled srcA 1) || fail "A: first handled failed"
assert_contains "$OUT" "handled: srcA 1" "A: first handled must report first-time handling"
assert_not_contains "$OUT" "already-handled" "A: first handled must not report a repeat"
OUT=$(pe handled srcA 1) || fail "A: repeat handled failed"
assert_contains "$OUT" "already-handled: srcA 1" "A: repeat handled must report a repeat"
pass "cs-procevent: handled distinguishes first-time from repeat acknowledgement"

: > "$QUEUE"
pe reconcile >/dev/null || fail "A: reconcile after handled failed"
[ ! -s "$QUEUE" ] || fail "A: an acknowledged result must never be re-announced:
$(cat "$QUEUE")"
pass "cs-procevent: an acknowledged result stops being re-announced"

# --- B: one distinct wake per captured result --------------------------------

: > "$QUEUE"
printf 'B payload\n' > "$TMP/payload-b"
pe register fixture srcB -- "$TMP/fast.sh" "$TMP/payload-b" >/dev/null || fail "B: register failed"
pe reconcile >/dev/null || fail "B: first reconcile failed"
wait_for 20 "B's first result" test -f "$INBOX/srcB.1.result"
wait_for 20 "B's first runner to release its claim" bash -c "[ ! -e '$CLAIMS/srcB.claim' ]"
pe reconcile >/dev/null || fail "B: second reconcile failed"
wait_for 20 "B's second result" test -f "$INBOX/srcB.2.result"
pe retire srcB >/dev/null || fail "B: retire failed"
pe reconcile >/dev/null || fail "B: republish failed"

KEYS=$(queue_keys | grep ':srcB:' | LC_ALL=C sort)
[ "$KEYS" = "procevent:srcB:1
procevent:srcB:2" ] || fail "B: expected exactly two distinct wake keys, got:
$KEYS"
pass "cs-procevent: each captured result gets its own distinct durable wake"

# --- C: the leader-crash / group-alive cut -----------------------------------

WITNESS_C="$TMP/witness-c"
: > "$WITNESS_C"
printf 'C payload\n' > "$TMP/payload-c"
pe register fixture srcC -- "$TMP/blocker.sh" "$TMP/trigger-c" "$TMP/payload-c" "$WITNESS_C" >/dev/null \
  || fail "C: register failed"
pe reconcile >/dev/null || fail "C: reconcile failed"
wait_for 20 "C's runner record" test -s "$REG/srcC.runner"
wait_for 20 "C's blocking child to start" test -s "$WITNESS_C"
LEADER=$(cat "$REG/srcC.runner")
poller_count "$WITNESS_C" 1 || fail "C: expected exactly one poller before the crash"

# Kill ONLY the leader. Its blocking child keeps consuming the source.
kill -KILL "$LEADER" 2>/dev/null || fail "C: could not kill the runner leader"
wait_for 20 "C's leader to die" bash -c "! kill -0 $LEADER 2>/dev/null"
kill -0 -"$LEADER" 2>/dev/null || fail "C: the blocking child's process group did not survive the crash"
pass "cs-procevent: killing the runner leader leaves its blocking child's group alive"

pe reconcile >/dev/null || fail "C: recovery reconcile failed"
wait_for 20 "C's orphaned group to be stopped" bash -c "! kill -0 -$LEADER 2>/dev/null"
wait_for 20 "C's replacement poller" poller_count "$WITNESS_C" 2

ALIVE=0
while IFS= read -r pid; do
  [ -n "$pid" ] || continue
  kill -0 "$pid" 2>/dev/null && ALIVE=$((ALIVE + 1))
done < "$WITNESS_C"
[ "$ALIVE" -eq 1 ] || fail "C: expected exactly one live poller after recovery, found $ALIVE"
pass "cs-procevent: reconcile stops the surviving group before starting one replacement"

pe retire srcC >/dev/null || fail "C: retire failed"
[ ! -e "$CLAIMS/srcC.claim" ] || fail "C: retire left the claim behind"

# --- D: adapter-owned terminal retirement ------------------------------------

: > "$QUEUE"
printf 'TERMINAL\n' > "$TMP/payload-d"
pe register fixture srcD -- "$TMP/fast.sh" "$TMP/payload-d" >/dev/null || fail "D: register failed"
pe reconcile >/dev/null || fail "D: reconcile failed"
wait_for 20 "D's result" test -f "$INBOX/srcD.1.result"
wait_for 20 "D's adapter-driven retirement" bash -c "[ ! -e '$REG/srcD.source' ]"
# Retirement drops the registration and releases the claim as two steps inside
# one lock hold (cs-procevent.sh), so an observer can catch the gap between
# them. Wait for the whole postcondition rather than asserting the second half
# the instant the first lands - that race made this fail only under load.
wait_for 20 "D's claim release" bash -c "[ ! -e '$CLAIMS/srcD.claim' ]"
assert_grep "procevent fixture srcD 1" "$QUEUE" "D: a terminal result is still published"

OUT=$(pe reconcile) || fail "D: post-retirement reconcile failed"
assert_contains "$OUT" "started=0" "D: an ended source must never be restarted"
[ ! -e "$INBOX/srcD.2.result" ] || fail "D: an ended source produced a second result"
pass "cs-procevent: an adapter's terminal verdict retires the source and stops restarts"

# --- E: an adapter with no terminal command keeps its source armed -----------

printf 'E payload\n' > "$TMP/payload-e"
pe register noterm srcE -- "$TMP/fast.sh" "$TMP/payload-e" >/dev/null || fail "E: register failed"
pe reconcile >/dev/null || fail "E: reconcile failed"
wait_for 20 "E's result" test -f "$INBOX/srcE.1.result"
[ -f "$REG/srcE.source" ] || fail "E: an adapter with no terminal command must keep its source armed"
pass "cs-procevent: an adapter with no terminal command leaves its source armed"
pe retire srcE >/dev/null || fail "E: retire failed"

# --- F: capo-home retirement safety ------------------------------------------

FAKEBIN=$(cs_fakebin "$TMP")
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
echo '{}'
exit 0
SH
chmod +x "$FAKEBIN/herdr"
export PATH="$FAKEBIN:$PATH"

CAPO="$TMP/capo-home"
mkdir -p "$CAPO/state"
printf 'testcapo\n' > "$CAPO/.cs-capo-home"
TD_STATE="$TMP/td-state"
TD_DATA="$TMP/td-data"
mkdir -p "$TD_STATE" "$TD_DATA"
cs_write_meta "$TD_STATE/testcapo.meta" \
  "kind=capo" "home=$CAPO" "pane=w9:p9" "workspace=w9"

capo_pe() {
  CS_ROOT_OVERRIDE="$TROOT" CS_HOME="$CAPO" CS_STATE_OVERRIDE="$CAPO/state" \
    CS_PROCEVENT_CLAIM_ROOT="$CLAIMS" bash "$TROOT/bin/cs-procevent.sh" "$@"
}

run_capo_teardown() {
  CS_HOME="$TMP" CS_STATE_OVERRIDE="$TD_STATE" CS_DATA_OVERRIDE="$TD_DATA" \
    CS_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    bash "$ROOT/bin/cs-teardown.sh" testcapo 2>&1
}

# An ownership state the home cannot prove it released: a live owner that does not
# lead its own process group, so stopping it can never be confirmed. Releasing
# that claim anyway is exactly what would leak a second destructive poller.
sleep 300 &
STUCK=$!
mkdir -p "$CLAIMS"
{
  printf '%s\n%s\n' "$CAPO" "$STUCK"
  printf 'tok-abc\n'
  cs_pid_identity "$STUCK"
  printf '%s\n' "$CAPO/state/procevent"
  printf '1:1\nactive\n'
} > "$CLAIMS/srcF.claim"
chmod 0600 "$CLAIMS/srcF.claim"

OUT=$(run_capo_teardown); RC=$?
expect_code 1 "$RC" "F: capo teardown must refuse while the home owns an unreleasable claim"
assert_contains "$OUT" "REFUSED" "F: the refusal must be explicit"
assert_contains "$OUT" "blocking sources" "F: the refusal must name the blocking-source hazard"
assert_present "$CAPO" "F: a refused capo teardown must leave the home in place"
assert_present "$CLAIMS/srcF.claim" "F: a refused capo teardown must leave the claim in place"
pass "cs-procevent: capo teardown refuses before removing a home that owns a claim"

kill "$STUCK" 2>/dev/null || true
wait "$STUCK" 2>/dev/null || true

# With the owner gone the claim is provably stale, and a plain registration is
# ordinary work: bounded retirement now clears both.
printf 'F payload\n' > "$TMP/payload-f"
capo_pe register fixture srcG -- "$TMP/fast.sh" "$TMP/payload-f" >/dev/null || fail "F: capo register failed"
capo_pe retire-home >/dev/null || fail "F: bounded home retirement failed once nothing was stuck"
[ ! -e "$CAPO/state/procevent/srcG.source" ] || fail "F: home retirement left a registration"
[ ! -e "$CLAIMS/srcF.claim" ] || fail "F: home retirement left a stale owned claim"
pass "cs-procevent: bounded home retirement clears this home's registrations and claims"

# --- G: an armed source alone keeps supervision required ---------------------

GHOME="$TMP/guard-home"
mkdir -p "$GHOME/bin" "$GHOME/state/procevent"
printf '# fixture\n' > "$GHOME/AGENTS.md"
printf 'guardcapo\n' > "$GHOME/.cs-capo-home"
: > "$GHOME/state/procevent/lavish-deadbeef.source"

OUT=$(CS_ROOT_OVERRIDE="$GHOME" CS_HOME="$GHOME" CS_GUARD_GRACE=1 \
  bash "$ROOT/bin/cs-guard.sh" 2>&1)
assert_contains "$OUT" "WATCHER DOWN" \
  "G: a home with an armed source and no tasks must still be warned"
assert_contains "$OUT" "1 blocking source(s) armed" \
  "G: the banner must name the armed source as the work at risk"

rm -f "$GHOME/state/procevent/lavish-deadbeef.source"
OUT=$(CS_ROOT_OVERRIDE="$GHOME" CS_HOME="$GHOME" CS_GUARD_GRACE=1 \
  bash "$ROOT/bin/cs-guard.sh" 2>&1)
assert_not_contains "$OUT" "WATCHER DOWN" \
  "G: a home with nothing in flight and nothing armed must stay silent"
pass "cs-procevent: cs-guard.sh treats an armed source as work needing supervision"

if command -v jq >/dev/null 2>&1; then
  : > "$GHOME/state/procevent/lavish-deadbeef.source"
  OUT=$(cd "$GHOME" && printf '{"stop_hook_active":false}' | \
    CS_ROOT_OVERRIDE="$GHOME" CS_HOME="$GHOME" CS_GUARD_GRACE=999 \
    CS_LOCK_HARNESS_RE='sleep|bash|zsh|codex|claude' \
    CS_MONITOR_BIN="$GHOME/no-such-monitor" \
    bash "$ROOT/bin/cs-turnend-guard.sh" 2>&1)
  RC=$?
  expect_code 2 "$RC" "G: a home that cannot wake itself must not end the turn with a source armed"
  assert_contains "$OUT" "THIS HOME CANNOT WAKE ITSELF" "G: the turn-end guard must block"
  assert_contains "$OUT" "1 blocking source(s) armed" \
    "G: the turn-end banner must name the armed source"
  pass "cs-procevent: cs-turnend-guard.sh blocks an unwakeable turn end with only a source armed"
else
  pass "cs-procevent: turn-end guard case skipped (jq not installed)"
fi
