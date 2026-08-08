#!/usr/bin/env bash
# Behavior (portable): bin/cs-startup-network.sh, the deferred network stage of
# a session start, and the NETWORK CHECKS section it composes.
#
# The session-start digest runs on a session-open hook that blocks session
# initialization, so it is now composed from local reads alone and every
# external-network call runs in this detached bounded worker instead. Deferral
# is only safe if three things hold, so each is pinned here:
#   - the result always surfaces: inline when a live claimant harvests it in
#     time, and as a durable `check: startup-network` wake when it does not,
#     with only a recorded delivery suppressing that wake;
#   - a worker never sweeps for a session it cannot prove owns the fleet lock -
#     it refuses to reserve one, and a hand-run pass downgrades to the
#     read-only probe rather than sweeping on someone else's authority;
#   - while the checks are still running the digest names EXACTLY what is not
#     yet confirmed and never prints anything that reads as passed.
# The closing case drives the real bin/cs-session-start.sh against a slow
# network dependency end to end: the digest completes with the stage still
# running, keeps its truncation-safe section order, and the result that lands
# afterwards still reaches the queue.
#
# Hermetic: gh, herdr, and the axi family are stubbed, and the one project
# clone is deliberately not a git repo, so fleet sync reports it and returns
# before any fetch. Nothing here touches the network or a live herdr server.
set -u

# Run the whole suite beneath one long-lived harness-named fixture shell, the
# same way tests/cs-sessionstart-run.test.sh does: cs-lock.sh resolves lock
# ownership by walking the process ancestry for a harness, and the mutating
# paths below are exactly the ones that must refuse when that walk does not
# reach the session the lock names.
if [ "${CS_STARTUP_NETWORK_TEST_HARNESS:-0}" != 1 ]; then
  HARNESS_FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/cs-startup-network-harness.XXXXXX") || exit 1
  ln -s /bin/bash "$HARNESS_FIXTURE/codex" || exit 1
  # shellcheck disable=SC2016 # Expand in the fixture shell, not this parent.
  CS_STARTUP_NETWORK_TEST_HARNESS=1 "$HARNESS_FIXTURE/codex" \
    -c '"$@"; rc=$?; :; exit "$rc"' _ "$0" "$@"
  HARNESS_STATUS=$?
  rm -rf "$HARNESS_FIXTURE"
  exit "$HARNESS_STATUS"
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(cs_test_tmproot cs-startup-network)
SNET="$ROOT/bin/cs-startup-network.sh"
SESSION_START="$ROOT/bin/cs-session-start.sh"
FIXTURE_PID=$PPID
cs_git_identity

# A worker detached by a case below outlives the command that launched it by
# design, so the suite reaps its own strays instead of leaving them running.
STRAY_HOMES=()
cleanup_workers() {
  local home pid
  for home in "${STRAY_HOMES[@]:-}"; do
    [ -n "$home" ] || continue
    pid=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status" 2>/dev/null | tail -1)
    case "$pid" in
      ''|*[!0-9]*|0) continue ;;
    esac
    kill "$pid" 2>/dev/null || true
  done
  cs_test_cleanup
}
trap cleanup_workers EXIT

# The fixture "consigliere repo": a plain checkout on its default branch, so
# nothing here depends on which branch the developer's real checkout is on.
FIX_ROOT="$TMP/root"
mkdir -p "$FIX_ROOT"
git init -q -b main "$FIX_ROOT"
git -C "$FIX_ROOT" commit -q --allow-empty -m init
: > "$FIX_ROOT/AGENTS.md"

# fakebin <dir> [<gh-auth-sleep-seconds>] - gh must be PRESENT and
# unauthenticated so the probe has a line to report; the optional sleep is the
# deliberately slow network dependency.
fakebin() {
  local fb=$1 slow=${2:-0} t
  mkdir -p "$fb"
  cat > "$fb/gh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = auth ] && [ "$slow" != 0 ]; then sleep $slow; fi
exit 1
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fb/gh" "$fb/herdr"
  for t in gh-axi tasks-axi lavish-axi quota-axi; do
    cs_fake_version_tool "$fb" "$t" "CS_TEST_UNUSED_VERSION" 9.9.9
  done
  printf '%s\n' "$fb"
}

# fresh_home <name> - an isolated CS_HOME carrying the two deterministic
# fixtures the sweeps report on: a project directory that is not a git repo
# (fleet sync, the network half) and a malformed capo registry row (the capo
# sweep, the local half). Whether the capo line appears is exactly how a case
# tells the two halves apart.
fresh_home() {
  local h="$TMP/$1"
  rm -rf "$h"
  mkdir -p "$h/config" "$h/state" "$h/data" "$h/host" "$h/projects/plainproj"
  printf -- '- broken-capo - no structured fields here\n' > "$h/host/capos.md"
  STRAY_HOMES+=("$h")
  printf '%s\n' "$h"
}

snet() {  # <home> <fakebin> <args...>
  local home=$1 fb=$2
  shift 2
  PATH="$fb:$PATH" CS_HOME="$home" CS_ROOT_OVERRIDE="$FIX_ROOT" "$SNET" "$@"
}

write_status() {  # <home> <key=value>...
  local home=$1
  shift
  printf '%s\n' "$@" > "$home/state/.startup-network.status"
}

# --- a finished probe publishes a durable report and surfaces as a wake --------
HOME_DIR=$(fresh_home probe)
FB=$(fakebin "$TMP/fb-probe")
snet "$HOME_DIR" "$FB" run --locked 0 || fail "a probe-only run must succeed"

assert_grep 'NEEDS_GH_AUTH:' "$HOME_DIR/state/.startup-network.report" \
  "the probe did not publish the gh auth verdict"
assert_no_grep 'FLEET_SYNC:' "$HOME_DIR/state/.startup-network.report" \
  "a probe-only run ran a mutating sweep"
# No claimant was ever registered, so the only way this result can reach an
# agent is the durable queue. That is the whole no-loss argument.
assert_grep 'check	startup-network' "$HOME_DIR/state/.wake-queue" \
  "a finished result with no live claimant did not surface as a wake"
assert_grep 'cs-startup-network.sh report' "$HOME_DIR/state/.wake-queue" \
  "the wake did not name the command that prints the result"
pass "a finished deferred result is durable and surfaces as a check wake"

# --- harvest prints the finished result and records the delivery --------------
out=$(snet "$HOME_DIR" "$FB" harvest --pid $$)
assert_contains "$out" 'completed off the startup path' "harvest did not report the finished stage"
assert_contains "$out" 'NEEDS_GH_AUTH:' "harvest did not print the published report"
assert_contains "$out" 'These ran AFTER the sections above were composed' \
  "harvest did not warn that these results postdate the digest above them"
assert_present "$HOME_DIR/state/.startup-network.delivered" \
  "harvest did not record the delivery that suppresses the wake"
pass "harvest prints the finished result and records its delivery"

# --- an unfinished stage is named as unconfirmed, never as passed -------------
HOME_DIR=$(fresh_home pending)
FB=$(fakebin "$TMP/fb-pending")
sleep 30 &
LIVE_PID=$!
write_status "$HOME_DIR" state=running "pid=$LIVE_PID" "started=$(date +%s)" \
  locked=1 phases=probe,sweeps generation=g-pending lock_pid=1234
out=$(snet "$HOME_DIR" "$FB" harvest --pid $$)
kill "$LIVE_PID" 2>/dev/null || true

assert_contains "$out" 'IN PROGRESS' "an unfinished stage did not say so"
assert_contains "$out" 'NOT yet confirmed: GitHub authentication, and project clone refresh' \
  "an unfinished stage did not name exactly which checks are unconfirmed"
assert_contains "$out" 'treat none of it as confirmed' \
  "an unfinished stage did not tell the reader what its silence means"
assert_not_contains "$out" 'completed off the startup path' \
  "an unfinished stage reported itself as completed"
assert_not_contains "$out" 'silent - no problems found' \
  "an unfinished stage read as a clean pass"
assert_absent "$HOME_DIR/state/.startup-network.delivered" \
  "an unfinished stage was acknowledged as delivered"
pass "a still-running stage names what is unconfirmed and never reads as passed"

# --- a worker that died before publishing is reported, not believed -----------
HOME_DIR=$(fresh_home dead)
FB=$(fakebin "$TMP/fb-dead")
bash -c 'exit 0' &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
write_status "$HOME_DIR" state=running "pid=$DEAD_PID" "started=$(date +%s)" \
  locked=1 phases=probe,sweeps generation=g-dead lock_pid=1234
out=$(snet "$HOME_DIR" "$FB" report)
assert_contains "$out" 'NETWORK_CHECKS: the deferred check worker stopped before publishing' \
  "a worker that died before publishing was not reported"
assert_contains "$out" 'cs-startup-network.sh run --locked 1' \
  "the report did not name how to rerun the stage"
pass "a worker that stopped before publishing is reported with its rerun command"

# --- mutation authority: a foreign lock owner gets no mutating pass ------------
HOME_DIR=$(fresh_home foreign)
FB=$(fakebin "$TMP/fb-foreign")
printf '424242\n' > "$HOME_DIR/state/.lock"

status=0
snet "$HOME_DIR" "$FB" start --locked 1 --harvest-pid $$ >/dev/null 2>&1 || status=$?
[ "$status" -ne 0 ] || fail "start reserved a mutating pass against a lock this session does not own"
assert_absent "$HOME_DIR/state/.startup-network.status" \
  "a refused start still reserved a generation"

snet "$HOME_DIR" "$FB" run --locked 1 || fail "a downgraded run must still publish its probe"
assert_grep 'NETWORK_CHECKS: the fleet lock was no longer held' \
  "$HOME_DIR/state/.startup-network.report" \
  "a downgraded run did not report the sweep it skipped"
assert_no_grep 'FLEET_SYNC:' "$HOME_DIR/state/.startup-network.report" \
  "a downgraded run swept on a lock it does not own"
assert_grep 'NEEDS_GH_AUTH:' "$HOME_DIR/state/.startup-network.report" \
  "a downgraded run withheld the read-only probe it is still entitled to"
pass "a pass that cannot prove lock ownership downgrades to the read-only probe"

# --- the owning session runs the network half, and only the network half ------
HOME_DIR=$(fresh_home owned)
FB=$(fakebin "$TMP/fb-owned")
printf '%s\n' "$FIXTURE_PID" > "$HOME_DIR/state/.lock"
snet "$HOME_DIR" "$FB" run --locked 1 || fail "an owned mutating run must succeed"

assert_grep 'FLEET_SYNC: plainproj: skipped: not a git repo' \
  "$HOME_DIR/state/.startup-network.report" "the owned run did not sweep project clones"
assert_grep 'NEEDS_GH_AUTH:' "$HOME_DIR/state/.startup-network.report" \
  "the owned run did not probe gh auth"
assert_no_grep 'CAPO_SYNC:' "$HOME_DIR/state/.startup-network.report" \
  "the deferred stage ran the LOCAL capo sweep, which belongs on the digest path"
assert_no_grep 'NETWORK_CHECKS:' "$HOME_DIR/state/.startup-network.report" \
  "an owned run reported an ownership change that did not happen"
pass "the lock-owning session runs exactly the network half"

# --- single flight: a live worker is adopted, never raced ---------------------
# One live worker IS the mutual exclusion for the mutating sweeps, so a session
# that finds one leaves it alone and adopts its result instead of starting a
# second pass over the same clones - even though this session owns the lock and
# the running worker started under a different one.
HOME_DIR=$(fresh_home single-flight)
FB=$(fakebin "$TMP/fb-single-flight")
printf '%s\n' "$FIXTURE_PID" > "$HOME_DIR/state/.lock"
sleep 30 &
LIVE_PID=$!
write_status "$HOME_DIR" state=running "pid=$LIVE_PID" "started=$(date +%s)" \
  locked=1 phases=probe,sweeps generation=g-inflight lock_pid=999999
snet "$HOME_DIR" "$FB" start --locked 1 --harvest-pid $$ \
  || fail "start refused to adopt a live worker"
generation=$(sed -n 's/^generation=//p' "$HOME_DIR/state/.startup-network.status" | tail -1)
[ "$generation" = g-inflight ] \
  || fail "start reserved a second worker beside a live one (generation is now '$generation')"
assert_grep 'g-inflight' "$HOME_DIR/state/.startup-network.claim" \
  "the adopting session did not claim the running worker's result"
kill "$LIVE_PID" 2>/dev/null || true
pass "a live worker is adopted rather than raced by a second mutating pass"

# --- a live claimant that harvests in time suppresses the wake ----------------
HOME_DIR=$(fresh_home claimed)
FB=$(fakebin "$TMP/fb-claimed")
printf '%s\n' "$FIXTURE_PID" > "$HOME_DIR/state/.lock"
snet "$HOME_DIR" "$FB" start --locked 1 --harvest-pid $$ \
  || fail "the owning session could not start the deferred stage"
snet "$HOME_DIR" "$FB" wait 60 || fail "the detached worker never published"
out=$(snet "$HOME_DIR" "$FB" harvest --pid $$)
assert_contains "$out" 'FLEET_SYNC: plainproj: skipped: not a git repo' \
  "the inline harvest did not print the detached worker's result"
assert_present "$HOME_DIR/state/.startup-network.delivered" \
  "an inline harvest did not record its delivery"
# The worker is still in its delivery window; give it room to observe the
# acknowledgement and exit without queueing a redundant wake.
sleep 2
! grep -q 'startup-network' "$HOME_DIR/state/.wake-queue" 2>/dev/null \
  || fail "a result already printed inline was queued as a wake as well"
pass "an inline harvest delivers the result and suppresses its wake"

# --- end to end: a slow network never blocks the digest -----------------------
# The one case that drives the real session-start digest. gh auth hangs, so the
# deferred stage is guaranteed to still be running when the digest is composed.
HOME_DIR=$(fresh_home digest)
FB=$(fakebin "$TMP/fb-digest" 6)
digest=$(PATH="$FB:$PATH" CS_HOME="$HOME_DIR" CS_ROOT_OVERRIDE="$FIX_ROOT" \
  "$SESSION_START" 2>/dev/null)

assert_contains "$digest" 'lock acquired' "the digest fixture did not acquire the fleet lock"
assert_contains "$digest" 'IN PROGRESS - the deferred network checks have not finished yet' \
  "the digest waited for the network checks instead of naming them unconfirmed"
assert_not_contains "$digest" 'NEEDS_GH_AUTH:' \
  "the digest blocked on the gh auth probe it is supposed to defer"
assert_contains "$digest" 'CAPO_SYNC: skipped: malformed capo registry entry' \
  "the digest deferred the LOCAL capo sweep along with the network half"

section_line() { printf '%s\n' "$1" | grep -n "^$2\$" | head -1 | cut -d: -f1; }
fleet_line=$(section_line "$digest" 'FLEET STATE')
network_line=$(section_line "$digest" 'NETWORK CHECKS')
context_line=$(section_line "$digest" 'CONTEXT')
if [ -z "$fleet_line" ] || [ -z "$network_line" ] || [ -z "$context_line" ]; then
  fail "the digest lost a section header: $digest"
fi
# Truncation-safe order: actionable network findings sit ahead of the curated
# memory a truncated tail is meant to take first, and behind the live fleet
# identity recovery depends on.
[ "$fleet_line" -lt "$network_line" ] || fail "NETWORK CHECKS printed ahead of FLEET STATE"
[ "$network_line" -lt "$context_line" ] || fail "NETWORK CHECKS printed after CONTEXT"

# And the result the digest could not wait for still reaches the queue.
snet "$HOME_DIR" "$FB" wait 90 || fail "the deferred stage never published after the digest"
found=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q 'startup-network' "$HOME_DIR/state/.wake-queue" 2>/dev/null; then
    found=1
    break
  fi
  sleep 1
done
[ "$found" -eq 1 ] || fail "the deferred result never surfaced after the digest was already out"
assert_grep 'NEEDS_GH_AUTH:' "$HOME_DIR/state/.startup-network.report" \
  "the deferred stage published no gh auth verdict"
pass "a slow network delays a reported check, never the digest"

pass "cs-startup-network deferred stage"
