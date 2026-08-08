#!/usr/bin/env bash
# cs-startup-network.sh - the deferred network stage of a session start.
#
# WHY THIS EXISTS. Every external-network call a session start makes used to run
# BEFORE the digest printed, on a hook that blocks session initialization:
# `gh auth status`, and the fleet-sync `git fetch origin --prune` of every
# project clone. Neither is individually bounded, so one unreachable remote
# could consume the whole CS_SESSION_START_TIMEOUT budget and truncate the
# digest outright, turning a slow network into a startup that never printed the
# work queue at all. This script runs exactly that work OFF the blocking path:
# the digest is composed from local reads alone while these checks run
# concurrently in a detached worker, and their result is reported back inline
# when it finishes in time, or as a durable wake when it does not.
#
# WHICH CHECKS ARE DEFERRED, and why the capo sweeps are not. The split is by
# whether a step leaves this machine, not by how slow it looks. `gh auth status`
# and the fleet-sync fetch do; bin/cs-home-seed.sh --sweep does not - a capo
# home is a plain detached git worktree of this repo on this same machine, its
# fast-forward resolves against the primary checkout with no fetch, and its
# liveness probe asks the local herdr server. Tool detection, the herdr health
# probe, and the worktree-tangle check are local for the same reason. Deferring
# a local step would buy nothing and would cost the digest an ordering guarantee
# it already has.
#
# WHAT IS PRESERVED. Nothing is dropped. bin/cs-bootstrap.sh remains the single
# owner of every one of these sweeps and still runs all of them, unchanged, via
# its CS_BOOTSTRAP_NETWORK=only phase. Deferral changes WHEN they run, not
# WHETHER, and three properties make the later run safe:
#   - The sweeps are idempotent DETECTORS. A run whose report is lost (killed
#     worker, truncated digest, crashed session) loses no finding: the next run
#     re-derives the same broken auth and the same stuck clone. There is no
#     once-only signal to miss.
#   - The result is durable and always surfaces. It lands in
#     state/.startup-network.report and reaches the agent either inline in the
#     digest or as a `check: startup-network` wake. Only a durable
#     acknowledgement written after a harvest prints the finished result
#     suppresses that wake, so a claimant that exits first cannot lose the
#     result. While the worker is still running the digest states by name what
#     is not yet confirmed, and never reports an unconfirmed check as passed.
#   - Mutation authority is re-verified. The worker outlives the command that
#     launched it, so it re-checks that state/.lock still names the session that
#     asked before it runs a mutating sweep, and downgrades to the read-only
#     probe when it does not.
#
# Usage: cs-startup-network.sh start --locked <0|1> --harvest-pid <pid>
#          Launch the detached worker and return immediately. Single-flight: a
#          worker already running for the same lock owner is left alone.
#          --locked 1 asks for the mutating sweeps as well as the read-only
#          probe; --locked 0 asks for the probe only. --harvest-pid names the
#          session-start process that will try to print the result inline, so
#          the worker can tell whether a wake is still needed.
#        cs-startup-network.sh run --locked <0|1>
#          Run the checks in the foreground and publish the result. This is what
#          `start` detaches with its private generation reservation; run it
#          directly to redo the stage by hand from the lock-owning session.
#          A hand-run `--locked 1` proves ownership the same way a new session
#          would - state/.lock must name THIS session's own harness - and
#          downgrades to the probe when it cannot.
#        cs-startup-network.sh harvest [--pid <pid>]
#          Print the digest's NETWORK CHECKS section and release the
#          inline-print claim. Called by bin/cs-session-start.sh, not by hand.
#        cs-startup-network.sh report
#          Print the current state and report without changing anything.
#        cs-startup-network.sh wait [<seconds>]
#          Block until the report is published, up to <seconds> (default 120).
#          For operators and tests only; a session start never waits.
#
# STATE, all under this home's state/ and gitignored with it:
#   .startup-network.status   key=value record - generation, lock_pid, state,
#                             pid, started, finished, rc, locked, phases, and
#                             whether the report was published. The single
#                             source of truth for what ran and how it ended.
#   .startup-network.report   the sweep output, byte for byte as
#                             bin/cs-bootstrap.sh produced it, plus a
#                             NETWORK_CHECKS: line whenever the stage itself
#                             could not complete or had to downgrade.
#   .startup-network.claim    the generation and pid of a session start that
#                             intends to print the result inline; a matching
#                             live claimant gives harvest a bounded chance to
#                             finish before a wake is queued.
#   .startup-network.delivered
#                             a durable acknowledgement that a harvest printed
#                             the current finished result; only this suppresses
#                             its wake.
#   .startup-network.lock     serializes publication, harvest acknowledgement,
#                             and the wake decision.
#
# The whole stage is bounded by CS_STARTUP_NETWORK_TIMEOUT (default 120s), one
# aggregate deadline replacing the per-call unboundedness that used to be able
# to wedge a startup. Hitting the bound is reported as an actionable
# NETWORK_CHECKS: line, never as silence.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
# cs-wake-lib.sh owns both the portable lock helpers used below and the durable
# wake queue this stage publishes into.
# shellcheck source=bin/cs-wake-lib.sh
. "$SCRIPT_DIR/cs-wake-lib.sh"
# shellcheck source=bin/cs-timeout-lib.sh
. "$SCRIPT_DIR/cs-timeout-lib.sh"

STATUS_FILE="$STATE/.startup-network.status"
REPORT_FILE="$STATE/.startup-network.report"
CLAIM_FILE="$STATE/.startup-network.claim"
DELIVERED_FILE="$STATE/.startup-network.delivered"
PUBLISH_LOCK="$STATE/.startup-network.lock"

usage() {
  sed -n '2,/^set -u$/p' "$SCRIPT_DIR/cs-startup-network.sh" | sed 's/^# \{0,1\}//; $d'
}

status_get() {  # <key>
  [ -f "$STATUS_FILE" ] || return 0
  sed -n "s/^$1=//p" "$STATUS_FILE" 2>/dev/null | tail -1
}

write_atomic() {  # <dest>, content on stdin
  local dest=$1 tmp
  tmp=$(mktemp "$dest.XXXXXX" 2>/dev/null) || return 1
  if cat > "$tmp" 2>/dev/null && mv -f "$tmp" "$dest" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

now() { date +%s; }

age_of() {  # <epoch> - seconds since, or empty when unreadable
  local then=$1
  case "$then" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$(( $(now) - then ))"
}

stage_budget() {
  local budget=${CS_STARTUP_NETWORK_TIMEOUT:-120}
  case "$budget" in ''|*[!0-9]*|0) budget=120 ;; esac
  printf '%s' "$budget"
}

delivery_budget() {
  local budget=${CS_SESSION_START_TIMEOUT:-120}
  case "$budget" in ''|*[!0-9]*|0) budget=120 ;; esac
  printf '%s' "$budget"
}

# Is a `running` record a stage that is genuinely still in flight? Two
# independent proofs are required, because either one alone can lie: a recorded
# pid can be reused by an unrelated process, and a worker killed with its process
# group (which is what a truncated digest does) leaves the record behind
# untouched. A record that outlives the stage's own aggregate bound is therefore
# treated as abandoned no matter what its pid says, which keeps "in progress"
# from becoming a permanent state.
worker_alive() {
  local pid started age
  pid=$(status_get pid)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  started=$(status_get started)
  age=$(age_of "$started")
  case "$age" in ''|*[!0-9]*) return 0 ;; esac
  [ "$age" -le "$(( $(stage_budget) + 30 ))" ]
}

# The exact phase names the digest and the report use, so "what has not been
# confirmed yet" is always answerable from the status record alone.
phase_label() {  # <phases>
  case "$1" in
    probe) printf 'GitHub authentication' ;;
    probe,sweeps) printf 'GitHub authentication, and project clone refresh with its drift reporting' ;;
    *) printf 'the deferred network checks' ;;
  esac
}

# Does state/.lock still name <expected-pid>?
#
# The question is deliberately "does the lock still name the session that asked
# for this work?", not "is that session still alive". The hazard being closed is
# a SECOND session sweeping concurrently, and taking the lock is exactly what
# rewrites this value - bin/cs-lock.sh overwrites a dead holder's pid with its
# own. An unchanged value therefore proves no one else owns the sweeps, which is
# the whole guarantee. Requiring liveness instead would refuse to finish work
# nobody else has claimed, and the sweeps are idempotent, so finishing it is
# strictly better than abandoning it. A missing, unreadable, or replaced lock all
# fail closed to the read-only probe.
lock_unchanged() {  # <expected-pid>
  local expected=$1 current
  case "$expected" in ''|*[!0-9]*) return 1 ;; esac
  [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] || return 1
  current=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  [ "$current" = "$expected" ]
}

# Does state/.lock name THIS session, rather than merely someone?
#
# A mutating pass must never run on behalf of a session that is not the caller's
# own, so `start --locked 1` and a hand-run `run --locked 1` both prove
# ownership before anything is reserved. The proof is bin/cs-lock.sh's own
# ancestry walk, asked for through its `harness-pid` mode, so harness identity
# is never re-derived here and the two can never drift apart. The detached
# worker does not use this: its authority is the generation reservation `start`
# made for it while it still held the lock, plus lock_unchanged at run time.
session_lock_owned_by_self() {
  local mine current
  [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] || return 1
  current=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  case "$current" in ''|*[!0-9]*) return 1 ;; esac
  mine=$("$SCRIPT_DIR/cs-lock.sh" harness-pid 2>/dev/null) || return 1
  [ "$mine" = "$current" ]
}

# --- start -------------------------------------------------------------------

cmd_start() {  # <locked> <harvest-pid>
  local locked=$1 harvest_pid=$2 lock_pid generation worker_pid phases started
  local monitor_was_on=0
  mkdir -p "$STATE" 2>/dev/null || return 1
  # Captured HERE, at the moment the caller still holds the lock, and carried to
  # the worker: re-reading the lock later would only prove that SOME session
  # holds it, which is exactly the case this guard exists to reject.
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$lock_pid" in ''|*[!0-9]*) [ "$locked" != 1 ] || return 1 ;; esac
  # A mutating pass is reserved only for the session the lock actually names.
  if [ "$locked" = 1 ] && ! session_lock_owned_by_self; then
    return 1
  fi

  cs_lock_acquire_wait "$PUBLISH_LOCK"
  if [ "$(status_get state)" = running ] && worker_alive; then
    # A worker from this or a previous session is still going. Liveness alone is
    # the single-flight test, deliberately: whose lock it started under does not
    # change the fact that a second worker would run the same mutating sweeps
    # against the same clones concurrently, which is the one thing this stage
    # must never do. One live worker IS the mutual exclusion, so no separate
    # lease is needed. The caller adopts it and harvests its real state; the
    # phase label that harvest prints names exactly which checks that run
    # covers, so adopting a narrower pass can never read as a wider one having
    # passed. A worker that outlives the stage's own bound stops counting as
    # alive (see worker_alive), so this can never wedge permanently.
    generation=$(status_get generation)
    printf '%s\t%s\n' "$generation" "$harvest_pid" > "$CLAIM_FILE" 2>/dev/null || true
    cs_lock_release "$PUBLISH_LOCK"
    return 0
  fi

  generation="$(now).$$.$harvest_pid"
  started=$(now)
  phases=probe
  [ "$locked" != 1 ] || phases=probe,sweeps
  if ! write_atomic "$STATUS_FILE" <<EOF
state=running
pid=0
started=$started
locked=$locked
phases=$phases
generation=$generation
lock_pid=$lock_pid
EOF
  then
    cs_lock_release "$PUBLISH_LOCK"
    return 1
  fi

  # Detached three ways, each closing a different failure:
  #   - stdio to /dev/null, because the digest's stdout is a pipe the harness
  #     reads to EOF; a worker holding that pipe open would strand session
  #     initialization behind the very work this stage exists to take off the
  #     blocking path.
  #   - nohup, so the worker outlives the shell that launched it.
  #   - its OWN process group (monitor mode), because the caller runs inside the
  #     digest's bounded child and bin/cs-timeout-lib.sh terminates that child's
  #     whole process group. Sharing the group would kill the worker on a
  #     truncated startup and, worse, orphan the bootstrap child it had already
  #     launched into a separate group - leaving unbounded network work running
  #     with nothing left to bound it. Its own group means a truncated digest
  #     leaves this stage running under its own deadline, which is exactly the
  #     independence deferral is for.
  #
  # The publish lock is held ACROSS the launch and the pid write on purpose: the
  # worker's own first act is to take this lock and check that the record names
  # it, so holding it here is what stops the worker from reading the placeholder
  # pid and concluding it was never reserved.
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  nohup "$SCRIPT_DIR/cs-startup-network.sh" run --locked "$locked" \
    --lock-pid "$lock_pid" --generation "$generation" \
    >/dev/null 2>&1 </dev/null &
  worker_pid=$!
  if ! write_atomic "$STATUS_FILE" <<EOF
state=running
pid=$worker_pid
started=$started
locked=$locked
phases=$phases
generation=$generation
lock_pid=$lock_pid
EOF
  then
    kill "$worker_pid" 2>/dev/null || true
    cs_lock_release "$PUBLISH_LOCK"
    [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
    return 1
  fi
  printf '%s\t%s\n' "$generation" "$harvest_pid" > "$CLAIM_FILE" 2>/dev/null || true
  cs_lock_release "$PUBLISH_LOCK"
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  return 0
}

# --- run ---------------------------------------------------------------------

wake_payload() {  # <state>
  printf 'check: startup-network: deferred startup network checks finished (%s); read them with %s/bin/cs-startup-network.sh report' \
    "$1" "$CS_ROOT"
}

# Give the inline claimant a bounded chance to print the finished result, then
# fall back to the durable wake. Either path surfaces the result; only a
# recorded delivery suppresses the wake.
await_delivery() {  # <generation> <state>
  local generation=$1 state=$2 limit waited=0 claim_record claim_generation claim_pid claim_live
  limit=$(( $(delivery_budget) * 10 ))
  while [ "$waited" -lt "$limit" ]; do
    claim_live=0
    cs_lock_acquire_wait "$PUBLISH_LOCK"
    if [ "$(status_get generation)" != "$generation" ] || [ -f "$DELIVERED_FILE" ]; then
      cs_lock_release "$PUBLISH_LOCK"
      return 0
    fi
    if [ -f "$CLAIM_FILE" ]; then
      claim_record=$(cat "$CLAIM_FILE" 2>/dev/null || true)
      IFS=$'\t' read -r claim_generation claim_pid <<EOF
$claim_record
EOF
      if [ "$claim_generation" = "$generation" ]; then
        case "$claim_pid" in
          ''|*[!0-9]*) ;;
          *) kill -0 "$claim_pid" 2>/dev/null && claim_live=1 ;;
        esac
      fi
      [ "$claim_live" -eq 1 ] || rm -f "$CLAIM_FILE" 2>/dev/null || true
    fi
    if [ "$claim_live" -eq 0 ]; then
      cs_wake_append check startup-network "$(wake_payload "$state")" || true
      cs_lock_release "$PUBLISH_LOCK"
      return 0
    fi
    cs_lock_release "$PUBLISH_LOCK"
    sleep 0.1
    waited=$((waited + 1))
  done
  cs_lock_acquire_wait "$PUBLISH_LOCK"
  if [ "$(status_get generation)" != "$generation" ] || [ -f "$DELIVERED_FILE" ]; then
    cs_lock_release "$PUBLISH_LOCK"
    return 0
  fi
  cs_wake_append check startup-network "$(wake_payload "$state")" || true
  cs_lock_release "$PUBLISH_LOCK"
}

publish() {  # <generation> <state> <phases> <locked> <started> <rc> <output-file>
  local generation=$1 state=$2 phases=$3 locked=$4 started=$5 rc=$6 out=$7 report_published=1
  cs_lock_acquire_wait "$PUBLISH_LOCK"
  if [ "$(status_get generation)" != "$generation" ]; then
    cs_lock_release "$PUBLISH_LOCK"
    return 0
  fi
  if ! write_atomic "$REPORT_FILE" < "$out"; then
    state=failed
    rc=1
    report_published=0
  fi
  rm -f "$DELIVERED_FILE" 2>/dev/null || true
  write_atomic "$STATUS_FILE" <<EOF || true
state=$state
pid=$$
started=$started
finished=$(now)
rc=$rc
locked=$locked
phases=$phases
generation=$generation
lock_pid=$(status_get lock_pid)
report_published=$report_published
EOF
  cs_lock_release "$PUBLISH_LOCK"
  await_delivery "$generation" "$state"
}

cmd_run() {  # <locked> <lock-pid> <generation>
  local locked=$1 lock_pid=$2 generation=$3 phases started budget out rc
  local sweep_locked=0 downgraded=0 internal=0
  mkdir -p "$STATE" 2>/dev/null || return 1
  started=$(now)
  budget=$(stage_budget)
  phases=probe
  if [ -n "$generation" ]; then
    # The detached worker: its authority is the reservation `start` made for it
    # while it still held the publish lock, so a stale or replaced generation
    # means this process is not the worker that record names.
    cs_lock_acquire_wait "$PUBLISH_LOCK"
    if [ "$(status_get generation)" = "$generation" ] && [ "$(status_get pid)" = "$$" ]; then
      internal=1
      started=$(status_get started)
    fi
    cs_lock_release "$PUBLISH_LOCK"
    [ "$internal" -eq 1 ] || return 1
  elif [ "$locked" = 1 ]; then
    # A hand-run mutating pass: the caller must be the session the lock names.
    if session_lock_owned_by_self; then
      lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
    else
      downgraded=1
      locked=0
    fi
  fi

  if [ "$locked" = 1 ]; then
    if lock_unchanged "$lock_pid"; then
      sweep_locked=1
      phases=probe,sweeps
    else
      downgraded=1
    fi
  fi

  if [ "$internal" -eq 0 ]; then
    generation="$(now).$$.manual"
    cs_lock_acquire_wait "$PUBLISH_LOCK"
    if [ "$(status_get state)" = running ] && worker_alive; then
      cs_lock_release "$PUBLISH_LOCK"
      return 1
    fi
    write_atomic "$STATUS_FILE" <<EOF || true
state=running
pid=$$
started=$started
locked=$sweep_locked
phases=$phases
generation=$generation
lock_pid=$lock_pid
EOF
    cs_lock_release "$PUBLISH_LOCK"
  fi

  # Recorded into a temp file rather than straight into state/ so a run that is
  # killed mid-sweep cannot leave a half-written artifact where the previous
  # run's complete one used to be; publish() promotes it atomically at the end.
  out=$(mktemp "${TMPDIR:-/tmp}/cs-startup-network.XXXXXX" 2>/dev/null) || return 1
  rc=0
  if [ "$sweep_locked" -eq 1 ]; then
    cs_run_timed "$budget" env CS_BOOTSTRAP_NETWORK=only \
      CS_BOOTSTRAP_NETWORK_LOCK_PID="$lock_pid" \
      "$SCRIPT_DIR/cs-bootstrap.sh" >"$out" 2>&1 || rc=$?
  else
    cs_run_timed "$budget" env CS_BOOTSTRAP_NETWORK=only CS_BOOTSTRAP_DETECT_ONLY=1 \
      "$SCRIPT_DIR/cs-bootstrap.sh" >"$out" 2>&1 || rc=$?
  fi

  if [ "$downgraded" -eq 1 ]; then
    printf 'NETWORK_CHECKS: the fleet lock was no longer held by the session that requested these, so the project clone refresh was skipped; it belongs to whichever session holds the lock now\n' >> "$out"
  fi
  case "$rc" in
    0) publish "$generation" 'done' "$phases" "$sweep_locked" "$started" "$rc" "$out" ;;
    "$CS_TIMEOUT_UNAVAILABLE")
      printf 'NETWORK_CHECKS: the runtime bound could not be established, so %s never ran; fix TMPDIR and rerun %s/bin/cs-startup-network.sh run --locked %s\n' \
        "$(phase_label "$phases")" "$CS_ROOT" "$sweep_locked" >> "$out"
      publish "$generation" failed "$phases" "$sweep_locked" "$started" "$rc" "$out"
      ;;
    124)
      printf 'NETWORK_CHECKS: hit the %ss bound before finishing, so %s may be incomplete; rerun %s/bin/cs-startup-network.sh run --locked %s\n' \
        "$budget" "$(phase_label "$phases")" "$CS_ROOT" "$sweep_locked" >> "$out"
      publish "$generation" timeout "$phases" "$sweep_locked" "$started" "$rc" "$out"
      ;;
    *)
      printf 'NETWORK_CHECKS: the deferred check worker exited %s, so %s may be incomplete; rerun %s/bin/cs-startup-network.sh run --locked %s\n' \
        "$rc" "$(phase_label "$phases")" "$CS_ROOT" "$sweep_locked" >> "$out"
      publish "$generation" failed "$phases" "$sweep_locked" "$started" "$rc" "$out"
      ;;
  esac
  rm -f "$out" 2>/dev/null || true
  return 0
}

# --- harvest / report --------------------------------------------------------

print_finished() {  # <state>
  local state=$1 phases started finished took=unknown report_published
  phases=$(status_get phases)
  started=$(status_get started)
  finished=$(status_get finished)
  report_published=$(status_get report_published)
  case "$started$finished" in
    ''|*[!0-9]*) ;;
    *) took=$((finished - started)) ;;
  esac
  printf 'completed off the startup path in %ss: %s.\n' "$took" "$(phase_label "$phases")"
  [ "$state" = 'done' ] || printf 'The stage itself did not finish cleanly (%s) - the NETWORK_CHECKS line below names what to rerun.\n' "$state"
  if [ "$report_published" = 0 ]; then
    printf 'NETWORK_CHECKS: could not publish the deferred check report, so %s results are unavailable; rerun %s/bin/cs-startup-network.sh run --locked %s\n' \
      "$(phase_label "$phases")" "$CS_ROOT" "$(status_get locked)"
  elif [ -s "$REPORT_FILE" ]; then
    cat "$REPORT_FILE"
    printf 'These ran AFTER the sections above were composed, so re-read any record a line here names.\n'
  else
    printf '(silent - no problems found)\n'
  fi
}

print_pending() {
  local phases started age
  phases=$(status_get phases)
  started=$(status_get started)
  age=$(age_of "$started")
  printf 'IN PROGRESS - the deferred network checks have not finished yet.\n'
  printf 'NOT yet confirmed: %s.\n' "$(phase_label "$phases")"
  [ -z "$age" ] || printf 'Started %ss ago, bounded at %ss.\n' "$age" "$(stage_budget)"
  # shellcheck disable=SC2016  # The backticked wake name is literal digest text.
  printf 'The result is durable in state/.startup-network.report and arrives as a `check: startup-network` wake.\n'
  printf 'Read it now with %s/bin/cs-startup-network.sh report; until it lands, treat none of it as confirmed.\n' "$CS_ROOT"
}

print_state() {
  case "$(status_get state)" in
    done|timeout|failed) print_finished "$(status_get state)" ;;
    running)
      if worker_alive; then
        print_pending
      else
        printf 'NETWORK_CHECKS: the deferred check worker stopped before publishing, so %s did not complete; rerun %s/bin/cs-startup-network.sh run --locked %s\n' \
          "$(phase_label "$(status_get phases)")" "$CS_ROOT" "$(status_get locked)"
      fi
      ;;
    *) printf 'not started - no deferred network checks have run for this home yet.\n' ;;
  esac
}

cmd_harvest() {  # <pid>
  local pid=$1 generation state claim_record claim_generation claim_pid
  cs_lock_acquire_wait "$PUBLISH_LOCK"
  generation=$(status_get generation)
  # Another session's live claim is left alone; the worker reaps a dead one.
  if [ -f "$CLAIM_FILE" ]; then
    claim_record=$(cat "$CLAIM_FILE" 2>/dev/null || true)
    IFS=$'\t' read -r claim_generation claim_pid <<EOF
$claim_record
EOF
    if [ "$claim_generation" = "$generation" ] \
      && { [ -z "$pid" ] || [ "$claim_pid" = "$pid" ]; }; then
      rm -f "$CLAIM_FILE" 2>/dev/null || true
    fi
  fi
  state=$(status_get state)
  print_state
  case "$state" in
    done|timeout|failed)
      [ "$(status_get report_published)" = 0 ] || write_atomic "$DELIVERED_FILE" <<EOF || true
delivered
EOF
      ;;
  esac
  cs_lock_release "$PUBLISH_LOCK"
}

cmd_wait() {  # <seconds>
  local limit=$1 waited=0
  case "$limit" in ''|*[!0-9]*) limit=120 ;; esac
  while [ "$waited" -lt "$limit" ]; do
    case "$(status_get state)" in
      done|timeout|failed) return 0 ;;
      running) worker_alive || return 1 ;;
    esac
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# --- entry -------------------------------------------------------------------

LOCKED=0
HARVEST_PID=
LOCK_PID=
GENERATION=
MODE=${1:-}
[ $# -eq 0 ] || shift
while [ $# -gt 0 ]; do
  case "$1" in
    --locked) LOCKED=${2:-0}; shift; [ $# -eq 0 ] || shift ;;
    --harvest-pid|--pid) HARVEST_PID=${2:-}; shift; [ $# -eq 0 ] || shift ;;
    --lock-pid) LOCK_PID=${2:-}; shift; [ $# -eq 0 ] || shift ;;
    --generation) GENERATION=${2:-}; shift; [ $# -eq 0 ] || shift ;;
    -h|--help) usage; exit 0 ;;
    *) break ;;
  esac
done
case "$LOCKED" in 0|1) ;; *) LOCKED=0 ;; esac

# `start` and `run` report their own refusals through the exit status, because
# bin/cs-session-start.sh has to tell "the stage is running" from "the stage was
# never started" - printing an unstarted stage as merely unfinished would name a
# check as pending that nothing is going to run. `harvest` and `report` are
# reporting commands and always exit 0.
RC=0
case "$MODE" in
  start) cmd_start "$LOCKED" "${HARVEST_PID:-0}" || RC=$? ;;
  run) cmd_run "$LOCKED" "$LOCK_PID" "$GENERATION" || RC=$? ;;
  harvest) cmd_harvest "${HARVEST_PID:-}" ;;
  report) print_state ;;
  wait) cmd_wait "${1:-120}" || RC=$? ;;
  -h|--help) usage ;;
  *)
    printf 'cs-startup-network: unknown mode: %s\n' "${MODE:-<none>}" >&2
    printf 'usage: cs-startup-network.sh start|run|harvest|report|wait\n' >&2
    exit 2
    ;;
esac
exit "$RC"
