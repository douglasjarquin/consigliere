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
# The two closing cases drive the real bin/cs-session-start.sh end to end
# against a hanging network dependency, one concern each so neither has to win a
# race: the digest completes with the stage still running and keeps its
# truncation-safe section order, and the result that lands after the digest is
# out still reaches the queue.
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
# A detached worker is its own process group leader, so the group is what has to
# be signalled: killing the worker alone would strand the network call it is
# blocked on.
stop_worker() {  # <home>
  local home=$1 pid
  pid=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status" 2>/dev/null | tail -1)
  case "$pid" in
    ''|*[!0-9]*|0) return 0 ;;
  esac
  kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
}
cleanup_workers() {
  local home
  for home in "${STRAY_HOMES[@]:-}"; do
    [ -n "$home" ] || continue
    stop_worker "$home"
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

# fakebin <dir> [<gate-file>] - gh must be PRESENT and unauthenticated so the
# probe has a line to report. The optional gate file is the deliberately slow
# network dependency, and it is a GATE rather than a sleep on purpose: a case
# that needs the worker still running while the digest is composed must not race
# a timer it can lose on a loaded machine. `gh auth status` blocks until the case
# creates that file, so "still running" and "finished" are both decided by the
# test rather than by scheduling.
fakebin() {
  local fb=$1 gate=${2:-} t
  mkdir -p "$fb"
  # The wait also ends when the fixture root disappears. cs_run_timed gives the
  # bounded command its OWN process group in every tier, so this stub is never in
  # the worker's group and a case that stops its worker cannot signal it; without
  # a second exit condition tied to cleanup, a stub whose gate is never created
  # would outlive the suite forever.
  cat > "$fb/gh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = auth ] && [ -n "$gate" ]; then
  while [ ! -e "$gate" ] && [ -d "$TMP" ]; do sleep 0.1; done
fi
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

# --- a torn or unreadable running record is never believed to be live ---------
# `start` reserves a generation with the placeholder `pid=0` before it launches
# the worker, so a start that dies between the two status writes leaves a
# `state=running pid=0` record behind. That placeholder must never read as a live
# worker: `kill -0 0` signals the caller's own process group and always succeeds,
# so believing it would make every later session adopt a worker that does not
# exist and drop its own network checks along with the wake that would have
# reported them.
HOME_DIR=$(fresh_home torn)
FB=$(fakebin "$TMP/fb-torn")
printf '%s\n' "$FIXTURE_PID" > "$HOME_DIR/state/.lock"
write_status "$HOME_DIR" state=running pid=0 "started=$(date +%s)" \
  locked=1 phases=probe,sweeps generation=g-torn lock_pid=999999
out=$(snet "$HOME_DIR" "$FB" report)
assert_contains "$out" 'NETWORK_CHECKS: the deferred check worker stopped before publishing' \
  "a torn reservation's pid=0 placeholder was reported as a live worker"
assert_not_contains "$out" 'IN PROGRESS' \
  "a torn reservation read as a stage still in progress"
snet "$HOME_DIR" "$FB" start --locked 1 --harvest-pid $$ \
  || fail "start refused to replace a torn reservation"
generation=$(sed -n 's/^generation=//p' "$HOME_DIR/state/.startup-network.status" | tail -1)
[ "$generation" != g-torn ] \
  || fail "start adopted the phantom pid=0 record instead of reserving a fresh generation"
stop_worker "$HOME_DIR"

# A start time that cannot be read cannot be shown to be inside the stage bound,
# so the bound is applied rather than skipped - otherwise one corrupt record
# holds "in progress" forever on the strength of a pid alone.
HOME_DIR=$(fresh_home corrupt)
FB=$(fakebin "$TMP/fb-corrupt")
sleep 30 &
LIVE_PID=$!
write_status "$HOME_DIR" state=running "pid=$LIVE_PID" started=not-an-epoch \
  locked=1 phases=probe,sweeps generation=g-corrupt lock_pid=999999
out=$(snet "$HOME_DIR" "$FB" report)
kill "$LIVE_PID" 2>/dev/null || true
assert_contains "$out" 'NETWORK_CHECKS: the deferred check worker stopped before publishing' \
  "a record whose start time cannot be read held 'in progress' on its pid alone"
pass "a torn or unreadable running record is abandoned rather than adopted as live"

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

# --- a later, narrower run never destroys a finished result nothing has read ---
# The re-emit sequence: a full startup's worker finishes after the digest is out,
# so its findings surface only as a queued wake that names
# `cs-startup-network.sh report`. Before that wake is drained the harness
# re-emits, which reserves a probe-only pass over the same state. That pass must
# not leave the wake pointing at a report that no longer contains what it
# announced.
HOME_DIR=$(fresh_home carry)
FB=$(fakebin "$TMP/fb-carry")
printf '%s\n' "$FIXTURE_PID" > "$HOME_DIR/state/.lock"
snet "$HOME_DIR" "$FB" run --locked 1 || fail "the owning session's run must publish"
assert_grep 'FLEET_SYNC: plainproj: skipped: not a git repo' \
  "$HOME_DIR/state/.startup-network.report" "the locked run published no fleet-sync finding"
assert_grep 'startup-network' "$HOME_DIR/state/.wake-queue" \
  "a finished result with no live claimant did not queue its wake"
assert_absent "$HOME_DIR/state/.startup-network.delivered" \
  "nothing harvested the result, yet it was recorded as delivered"

snet "$HOME_DIR" "$FB" start --locked 0 --harvest-pid $$ \
  || fail "the re-emit could not start its probe-only pass"
snet "$HOME_DIR" "$FB" wait 60 || fail "the probe-only pass never published"
out=$(snet "$HOME_DIR" "$FB" report)
assert_contains "$out" 'FLEET_SYNC: plainproj: skipped: not a git repo' \
  "the probe-only pass destroyed the unread finding its queued wake announced"
assert_contains "$out" 'Carried forward from the previous deferred run' \
  "the preserved finding was reprinted without saying which run it came from"
assert_contains "$out" 'NEEDS_GH_AUTH:' \
  "the probe-only pass did not publish its own result alongside the carried one"
snet "$HOME_DIR" "$FB" harvest --pid $$ >/dev/null
pass "a later narrower run preserves a finished result nothing has read yet"

# --- an abandoned reservation still protects the unread report under it -------
# A pass reserved over an unread report and was then killed before it could
# publish, so the record is left `running` while the report file still holds the
# earlier run's findings. The next reservation has to protect that report exactly
# as it would protect a cleanly finished one: how the record that produced it
# ended says nothing about whether anything has read it.
HOME_DIR=$(fresh_home abandoned)
FB=$(fakebin "$TMP/fb-abandoned")
printf '%s\n' "$FIXTURE_PID" > "$HOME_DIR/state/.lock"
snet "$HOME_DIR" "$FB" run --locked 1 || fail "the owning session's run must publish"
assert_grep 'FLEET_SYNC: plainproj: skipped: not a git repo' \
  "$HOME_DIR/state/.startup-network.report" "the locked run published no fleet-sync finding"
bash -c 'exit 0' &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
write_status "$HOME_DIR" state=running "pid=$DEAD_PID" "started=$(date +%s)" \
  locked=0 phases=probe requested=probe carried=1 generation=g-abandoned lock_pid=999999

snet "$HOME_DIR" "$FB" run --locked 0 || fail "a probe-only pass must publish over an abandoned record"
assert_grep 'FLEET_SYNC: plainproj: skipped: not a git repo' \
  "$HOME_DIR/state/.startup-network.report" \
  "reserving over an abandoned record destroyed the unread finding beneath it"
pass "an abandoned reservation does not expose the unread report beneath it"

# --- repeated runs that nothing harvests hold the report at a fixed shape ------
# The degraded cycle this stage exists for: a digest truncated between starting
# the stage and harvesting it never acknowledges the result, and the truncation
# banner tells the operator to rerun, so the cycle repeats. A hand-run
# `cs-startup-network.sh run` does the same. Each pass therefore reserves over an
# unread report and folds it forward, and the fold has to converge - this report
# is cat'd straight into the NETWORK CHECKS section, so a report that grew every
# cycle would start costing the digest the sections its ordering protects.
HOME_DIR=$(fresh_home carry-bound)
FB=$(fakebin "$TMP/fb-carry-bound")
REPORT="$HOME_DIR/state/.startup-network.report"
CARRY_HEADER='Carried forward from the previous deferred run, which finished before anything read it:'
printf '%s\n' "$FIXTURE_PID" > "$HOME_DIR/state/.lock"
snet "$HOME_DIR" "$FB" run --locked 1 || fail "the owning session's run must publish"

sizes=()
for _ in 1 2 3 4; do
  snet "$HOME_DIR" "$FB" run --locked 0 || fail "a hand-run probe pass must publish"
  sizes+=("$(wc -c < "$REPORT" | tr -d ' ')")
done
assert_absent "$HOME_DIR/state/.startup-network.delivered" \
  "nothing harvested these passes, yet a delivery was recorded"
[ "${sizes[1]}" = "${sizes[3]}" ] \
  || fail "the report kept growing across unharvested cycles (${sizes[0]} ${sizes[1]} ${sizes[2]} ${sizes[3]} bytes)"
blocks=$(grep -Fxc "$CARRY_HEADER" "$REPORT" || true)
[ "$blocks" = 1 ] || fail "the report carries $blocks carried blocks, not exactly one"
assert_grep 'FLEET_SYNC: plainproj: skipped: not a git repo' "$REPORT" \
  "the folds dropped the locked run's finding no later pass can re-derive"
assert_grep 'NEEDS_GH_AUTH:' "$REPORT" \
  "the report lost the latest pass's own result"
pass "repeated unharvested folds keep exactly one carried block and stop growing"

# --- adoption names the check the adopted run does not cover ------------------
# Single flight is liveness-only, so a lock-owning session that arrives while a
# probe-only pass is in flight adopts it rather than starting a second pass over
# the same clones. The fleet sync it asked for therefore does not run, and the
# section has to say so rather than leaving the reader to notice that the phase
# label never mentions it.
HOME_DIR=$(fresh_home narrow)
FB=$(fakebin "$TMP/fb-narrow")
printf '%s\n' "$FIXTURE_PID" > "$HOME_DIR/state/.lock"
sleep 30 &
LIVE_PID=$!
write_status "$HOME_DIR" state=running "pid=$LIVE_PID" "started=$(date +%s)" \
  locked=0 phases=probe requested=probe carried=0 generation=g-narrow lock_pid=999999
snet "$HOME_DIR" "$FB" start --locked 1 --harvest-pid $$ \
  || fail "start refused to adopt the live probe-only pass"
generation=$(sed -n 's/^generation=//p' "$HOME_DIR/state/.startup-network.status" | tail -1)
[ "$generation" = g-narrow ] \
  || fail "start raced a second pass beside the live one (generation is now '$generation')"
out=$(snet "$HOME_DIR" "$FB" harvest --pid $$)
kill "$LIVE_PID" 2>/dev/null || true
assert_contains "$out" 'NOT covered by this run: project clone refresh with its drift reporting' \
  "adopting a probe-only pass dropped the fleet sync without naming it"
assert_contains "$out" 'NOT yet confirmed: GitHub authentication' \
  "the adopted pass stopped naming the check it does cover"
assert_not_contains "$out" 'completed off the startup path' \
  "an adopted in-flight pass reported itself as completed"
pass "adopting a narrower pass names the check that pass does not cover"

# --- end to end: a slow network never blocks the digest -----------------------
# The real session-start digest, driven against a network dependency that is
# still hanging when the digest is composed. The hang is held open by a gate file
# this case never creates, so "the worker is still running" is a fact rather than
# a bet on the digest outrunning a timer.
HOME_DIR=$(fresh_home digest-blocked)
FB=$(fakebin "$TMP/fb-digest-blocked" "$TMP/gate-never")
digest=$(PATH="$FB:$PATH" CS_HOME="$HOME_DIR" CS_ROOT_OVERRIDE="$FIX_ROOT" \
  "$SESSION_START" 2>/dev/null)
# The hang has served its purpose the moment the digest is out, so the worker is
# stopped rather than waited out and the open-ended block costs the suite nothing.
# Releasing the gate afterwards is what lets the stub the worker left behind in
# its own process group finish and exit instead of spinning past the suite.
stop_worker "$HOME_DIR"
: > "$TMP/gate-never"

assert_contains "$digest" 'lock acquired' "the digest fixture did not acquire the fleet lock"
assert_contains "$digest" 'IN PROGRESS - the deferred network checks have not finished yet' \
  "the digest waited for the network checks instead of naming them unconfirmed"
assert_contains "$digest" 'NOT yet confirmed: GitHub authentication, and project clone refresh' \
  "the digest did not name exactly which checks were still unconfirmed"
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
pass "a hanging network dependency delays a reported check, never the digest"

# --- end to end: the deferred result surfaces after the digest is out ---------
# Same real digest, and the same gate holds the worker past the digest's inline
# harvest so the claim is released rather than satisfied. Releasing the gate then
# lets the worker finish promptly, and the only path left to the agent is the
# durable wake.
HOME_DIR=$(fresh_home digest-deferred)
GATE="$TMP/gate-deferred"
FB=$(fakebin "$TMP/fb-digest-deferred" "$GATE")
digest=$(PATH="$FB:$PATH" CS_HOME="$HOME_DIR" CS_ROOT_OVERRIDE="$FIX_ROOT" \
  "$SESSION_START" 2>/dev/null)
assert_contains "$digest" 'IN PROGRESS - the deferred network checks have not finished yet' \
  "the digest printed the result inline, so this case proves nothing about the wake path"
: > "$GATE"

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
pass "a result the digest could not wait for still reaches the agent as a wake"

pass "cs-startup-network deferred stage"
