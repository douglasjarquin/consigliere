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
#   - The result is durable and always surfaces. It reaches the agent either
#     inline in the digest or as a `check: startup-network` wake, and only a
#     durable acknowledgement written by a reader that actually PRINTED it
#     suppresses that wake, so a claimant that exits first cannot lose the
#     result. Both surfacing paths therefore end in an acknowledging read; see
#     the usage block below for which mode acknowledges what. While the worker
#     is still running the digest states by name what is not yet confirmed, and
#     never reports an unconfirmed check as passed.
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
#
# THE THREE READERS differ only in what they do to delivery state, and every
# result that gets printed has to be acknowledged by whoever printed it - an
# unacknowledged result is by definition still unread, so it would be queued as a
# wake again and re-presented later as one nothing has seen:
#        cs-startup-network.sh harvest [--pid <pid>]
#          Print the digest's NETWORK CHECKS section, release the matching
#          inline-print claim, and acknowledge exactly what it printed. Called by
#          bin/cs-session-start.sh, not by hand.
#        cs-startup-network.sh read
#          Print the same thing and acknowledge exactly what it printed, leaving
#          any claim alone because this reader is not the claimant. This is the
#          mode the `check: startup-network` wake names, so following that wake
#          ends the result's life as an unread one.
#        cs-startup-network.sh report
#          Print the current state and change nothing at all - no acknowledgement
#          and no drain, plus this stage's elapsed-time timeline. For an operator
#          who wants to look without consuming. It is the ONLY reader that prints
#          the timeline: `harvest` composes the session-start digest, whose bytes
#          this instrumentation must not change, and the wake reader `read` prints
#          what the digest would have.
#        cs-startup-network.sh wait [<seconds>]
#          Block until the report is published, up to <seconds> (default 120).
#          For operators and tests only; a session start never waits.
#
# RESULTS ARE NEVER MERGED. Two passes can cover different checks - a re-emit
# runs the probe alone, a full startup runs the sweeps too - so a result only
# means something together with the coverage it speaks for. Every published
# result is therefore a WHOLE self-describing unit: its first line records the
# phases that run covered, and nothing is ever folded, wrapped, or concatenated
# into it. A publish that would land on an unread result MOVES that result into
# the pending store first and then writes its own, so "which coverage wins" is
# never a question this stage has to answer.
#
# STATE, all under this home's state/ and gitignored with it:
#   .startup-network.status   key=value record - generation, lock_pid, state,
#                             pid, started, finished, rc, locked, phases,
#                             requested, and whether the report was published.
#                             The single source of truth for what ran and how it
#                             ended. `phases` is what the running pass COVERS;
#                             `requested` is the union of what every session
#                             attached to it ASKED for, so the difference is
#                             exactly what has to be named as not covered.
#   .startup-network.report   the CURRENT result: a `covered=<phases>` first
#                             line, then the sweep output byte for byte as
#                             bin/cs-bootstrap.sh produced it, plus a
#                             NETWORK_CHECKS: line whenever the stage itself
#                             could not complete or had to downgrade. Only the
#                             body is ever printed, so the reported lines are
#                             exactly what the unsplit blocking run printed.
#   .startup-network.pending/ results that finished and were never read, one
#                             whole result per file in the same format, named so
#                             the plain name order is oldest first. A harvest
#                             prints them ahead of the current result and then
#                             empties this directory, so a harvest always leaves
#                             it with nothing for the next publish to pend.
#                             It holds at most STARTUP_NETWORK_PENDING_MAX
#                             results; a publish that exceeds that drops the
#                             oldest and counts the drop in .pending/.dropped,
#                             which every harvest discloses by number.
#   .startup-network.timings  where this stage spent its time: one elapsed-time
#                             record per check owner and per item inside it, in
#                             bin/cs-timing-lib.sh's format, published beside the
#                             report by the same publish. A run that timed out or
#                             failed publishes what it had recorded so far, which
#                             is exactly the case the timeline exists to answer:
#                             the step still running when the bound hit is the one
#                             with no record.
#   .startup-network.claim    the generation and pid of a session start that
#                             intends to print the result inline; a matching
#                             live claimant gives harvest a bounded chance to
#                             finish before a wake is queued.
#   .startup-network.delivered
#                             a durable acknowledgement that an acknowledging
#                             reader printed the current result; only this
#                             suppresses its wake, and only its absence makes
#                             that result pendable. A publish clears it only when
#                             a new result actually replaced the one it
#                             acknowledged.
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
# cs-timing-lib.sh owns the elapsed-time record this stage asks its checks to
# write; nothing here knows the format.
# shellcheck source=bin/cs-timing-lib.sh
. "$SCRIPT_DIR/cs-timing-lib.sh"

STATUS_FILE="$STATE/.startup-network.status"
REPORT_FILE="$STATE/.startup-network.report"
PENDING_DIR="$STATE/.startup-network.pending"
DROPPED_FILE="$PENDING_DIR/.dropped"
TIMINGS_FILE="$STATE/.startup-network.timings"
CLAIM_FILE="$STATE/.startup-network.claim"
DELIVERED_FILE="$STATE/.startup-network.delivered"
PUBLISH_LOCK="$STATE/.startup-network.lock"

# How many unread results the pending store keeps. The bound is enforced by
# prune_pending on every pend, which removes oldest-first until the count is at
# or under it, so after any publish the store holds at most this many results no
# matter how many publishes preceded it and whether anything ever harvested.
STARTUP_NETWORK_PENDING_MAX=4

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

# Append one key to the status record, atomically, so a reader never sees a
# half-written file. status_get takes the LAST match, so an appended key wins
# over the one the record was written with. Callers hold the publish lock.
status_set() {  # <key> <value>
  [ -f "$STATUS_FILE" ] || return 0
  { cat "$STATUS_FILE" 2>/dev/null || true; printf '%s=%s\n' "$1" "$2"; } \
    | write_atomic "$STATUS_FILE" || true
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

# Is a `running` record a stage that is genuinely still in flight? Liveness has
# to be PROVEN, never assumed from a record's mere existence, because every way
# this record can be wrong reads as "still running" by default:
#   - The literal 0 that cmd_start writes to reserve a generation before the
#     launch is not a worker. `kill -0 0` signals the caller's OWN process group
#     and so always succeeds, which would turn a reservation torn between the
#     two status writes into a phantom worker that every later session adopts.
#   - A recorded pid can be reused by an unrelated process, and a worker killed
#     with its process group (which is what a truncated digest does) leaves the
#     record behind untouched. So a record that outlives the stage's own
#     aggregate bound is abandoned no matter what its pid says.
#   - A start time that cannot be read cannot be shown to be inside that bound,
#     so it fails the bound rather than skipping it. Believing it instead would
#     let one corrupt record hold "in progress" forever, which is precisely the
#     permanent state the bound exists to prevent.
worker_alive() {
  local pid started age
  pid=$(status_get pid)
  case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  started=$(status_get started)
  age=$(age_of "$started")
  case "$age" in ''|*[!0-9]*) return 1 ;; esac
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

# The widest of two phase sets. Adoption is liveness-only, so a session that
# attaches to a narrower live pass records what it ASKED for here rather than
# starting a second pass over the same clones.
phases_union() {  # <a> <b>
  case "$1,$2" in
    *sweeps*) printf 'probe,sweeps' ;;
    *) printf 'probe' ;;
  esac
}

# What a run was asked for but does not cover, named the same way the read-only
# branch of bin/cs-session-start.sh names the checks it skipped. Empty when the
# run covers everything asked of it.
uncovered_label() {  # <covered> <requested>
  case "$1" in *sweeps*) return 0 ;; esac
  case "$2" in *sweeps*) printf 'project clone refresh with its drift reporting' ;; esac
}

# --- results -----------------------------------------------------------------
# One format for the current result and every pending one, so a result read from
# either place answers "which checks does this speak for?" on its own.

result_covered() {  # <result-file>
  sed -n '1s/^covered=//p' "$1" 2>/dev/null
}

result_body() {  # <result-file>
  sed '1d' "$1" 2>/dev/null
}

result_has_body() {  # <result-file>
  [ -f "$1" ] || return 1
  [ -n "$(result_body "$1" | head -c 1)" ]
}

# Is the current result one that nothing has read? The predicate is exactly: no
# delivery was acknowledged, and the result has content. Nothing else belongs in
# it - not the status record's state, which describes the run that came AFTER the
# result rather than the result, and not report_published, which is 0 precisely
# when a write FAILED and so left the earlier unread result in place.
result_unread() {
  [ ! -f "$DELIVERED_FILE" ] || return 1
  result_has_body "$REPORT_FILE"
}

# Entry names, oldest first. The names are fixed-width counters, so the glob's
# own sort IS chronological order and no separate index has to be kept correct.
pending_names() {
  local entry name
  for entry in "$PENDING_DIR"/*; do
    [ -f "$entry" ] || continue
    name=${entry##*/}
    case "$name" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) printf '%s\n' "$name" ;;
    esac
  done
}

# Enforce the store's bound: drop oldest-first until the count is at or under it,
# counting every drop so a harvest can name the number. Called by pend_current on
# every pend, which is what makes the bound a property of the store rather than
# of how often callers happen to harvest.
prune_pending() {
  local names count over dropped
  names=$(pending_names)
  count=$(printf '%s' "$names" | grep -c . || true)
  over=$((count - STARTUP_NETWORK_PENDING_MAX))
  [ "$over" -gt 0 ] || return 0
  printf '%s\n' "$names" | grep . | head -n "$over" | while IFS= read -r name; do
    rm -f "$PENDING_DIR/$name" 2>/dev/null || true
  done
  dropped=$(cat "$DROPPED_FILE" 2>/dev/null || true)
  case "$dropped" in ''|*[!0-9]*) dropped=0 ;; esac
  printf '%s\n' "$((dropped + over))" > "$DROPPED_FILE" 2>/dev/null || true
}

# Move the current result into the store, whole and unchanged. A move, never a
# copy or a merge: the result that was there keeps its own coverage line and its
# own body, and the caller then has an empty slot to write its own result into.
pend_current() {
  local last next
  mkdir -p "$PENDING_DIR" 2>/dev/null || return 1
  last=$(pending_names | tail -1)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  next=$(printf '%012d' "$((10#$last + 1))")
  mv -f "$REPORT_FILE" "$PENDING_DIR/$next" 2>/dev/null || return 1
  prune_pending
  return 0
}

# Does state/.lock name THIS session, rather than merely someone?
#
# A mutating pass must never run on behalf of a session that is not the caller's
# own, so `start --locked 1` and a hand-run `run --locked 1` both prove
# ownership before anything is reserved. The proof is bin/cs-lock.sh's own
# ancestry walk, asked for through its `harness-pid` mode, so harness identity
# is never re-derived here and the two can never drift apart. The detached
# worker does not use this: its authority is the generation reservation `start`
# made for it while it still held the lock, plus bin/cs-lock.sh's `holds` check
# at run time.
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
  phases=probe
  [ "$locked" != 1 ] || phases=probe,sweeps
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
    # lease is needed, and adoption never starts a second pass.
    #
    # Adoption is therefore a DISCLOSURE problem, not a scheduling one. What the
    # caller asked for is recorded next to what the running pass covers, so a
    # session that adopts a narrower pass has the difference named for it by
    # print_pending and print_finished instead of having to infer a check's
    # absence from a phase label that simply never mentions it.
    #
    # A worker that outlives the stage's own bound stops counting as alive (see
    # worker_alive), so this can never wedge permanently.
    generation=$(status_get generation)
    status_set requested "$(phases_union "$(status_get requested)" "$phases")"
    printf '%s\t%s\n' "$generation" "$harvest_pid" > "$CLAIM_FILE" 2>/dev/null || true
    cs_lock_release "$PUBLISH_LOCK"
    return 0
  fi

  generation="$(now).$$.$harvest_pid"
  started=$(now)
  if ! write_atomic "$STATUS_FILE" <<EOF
state=running
pid=0
started=$started
locked=$locked
phases=$phases
requested=$phases
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
requested=$phases
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
  printf 'check: startup-network: deferred startup network checks finished (%s); read them with %s/bin/cs-startup-network.sh read' \
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

publish() {  # <generation> <state> <phases> <locked> <started> <rc> <output-file> <timings-file>
  local generation=$1 state=$2 phases=$3 locked=$4 started=$5 rc=$6 out=$7 timings=${8:-} report_published=1
  local requested
  cs_lock_acquire_wait "$PUBLISH_LOCK"
  if [ "$(status_get generation)" != "$generation" ]; then
    cs_lock_release "$PUBLISH_LOCK"
    return 0
  fi
  # The timeline belongs to the run that just ended, so a run that recorded
  # nothing REMOVES the previous one rather than leaving it to be read as this
  # run's. It is published for every outcome, including timeout and failure,
  # where the partial record is the answer.
  if [ -n "$timings" ] && [ -s "$timings" ]; then
    write_atomic "$TIMINGS_FILE" < "$timings" || true
  else
    rm -f "$TIMINGS_FILE" 2>/dev/null || true
  fi
  requested=$(phases_union "$(status_get requested)" "$phases")
  # An unread result is MOVED aside before this one is written, never merged with
  # it and never overwritten: the two can cover different checks, and the wake
  # that announced the older one still points at a `report` that must show it.
  # A pend that cannot be made is the one case where writing here would destroy
  # something unread, so it fails closed - the older result stays exactly where it
  # is and this publish reports that it could not land, which the rerun line names.
  if result_unread && ! pend_current; then
    state=failed
    rc=1
    report_published=0
  elif ! { printf 'covered=%s\n' "$phases"; cat "$out"; } | write_atomic "$REPORT_FILE"; then
    state=failed
    rc=1
    report_published=0
  else
    # Only here, where a new result actually landed: an acknowledgement names the
    # result it was written for, so a publish that could not replace that result
    # must leave its acknowledgement standing. Clearing it unconditionally would
    # resurrect an already-read result as unread and pend it into the store.
    rm -f "$DELIVERED_FILE" 2>/dev/null || true
  fi
  write_atomic "$STATUS_FILE" <<EOF || true
state=$state
pid=$$
started=$started
finished=$(now)
rc=$rc
locked=$locked
phases=$phases
requested=$requested
generation=$generation
lock_pid=$(status_get lock_pid)
report_published=$report_published
EOF
  cs_lock_release "$PUBLISH_LOCK"
  await_delivery "$generation" "$state"
}

cmd_run() {  # <locked> <lock-pid> <generation>
  local locked=$1 lock_pid=$2 generation=$3 phases started budget out rc timings=
  local sweep_locked=0 downgraded=0 internal=0
  # `run` is the command every printed remedy in this stage names, so each of its
  # refusals says why on the way out. A remedy that exits nonzero in silence is
  # worse than no remedy: the reader cannot tell a deliberate refusal from a
  # crash, and has nothing to act on either way.
  if ! mkdir -p "$STATE" 2>/dev/null; then
    printf 'NETWORK_CHECKS: %s could not be created, so the deferred network checks did not run; fix that directory and rerun %s/bin/cs-startup-network.sh run --locked %s\n' \
      "$STATE" "$CS_ROOT" "$locked"
    return 1
  fi
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

  # bin/cs-lock.sh owns "does the lock STILL name the pid this pass captured?",
  # and bin/cs-bootstrap.sh asks the same owner again before each sweep actually
  # runs, so the label written here and the work that happens cannot drift apart.
  if [ "$locked" = 1 ]; then
    if "$SCRIPT_DIR/cs-lock.sh" holds "$lock_pid" 2>/dev/null; then
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
      # The refusal itself is the single-flight guarantee and stays exactly as it
      # is - a second pass over the same clones is the one thing this stage must
      # never do. What it owes the reader is the reason, because this is the
      # command print_uncovered names and it is reached precisely while the pass
      # that left a check uncovered is still in flight.
      # shellcheck disable=SC2016  # The backticked wake name is literal report text.
      printf 'NETWORK_CHECKS: a deferred check pass is already in flight covering %s, so this did not start a second pass over the same clones; its result arrives inline in the next digest or as the queued `check: startup-network` wake, and rerunning after it finishes covers anything it does not\n' \
        "$(phase_label "$(status_get phases)")"
      cs_lock_release "$PUBLISH_LOCK"
      return 1
    fi
    write_atomic "$STATUS_FILE" <<EOF || true
state=running
pid=$$
started=$started
locked=$sweep_locked
phases=$phases
requested=$phases
generation=$generation
lock_pid=$lock_pid
EOF
    cs_lock_release "$PUBLISH_LOCK"
  fi

  # Recorded into a temp file rather than straight into state/ so a run that is
  # killed mid-sweep cannot leave a half-written artifact where the previous
  # run's complete one used to be; publish() promotes it atomically at the end.
  if ! out=$(mktemp "${TMPDIR:-/tmp}/cs-startup-network.XXXXXX" 2>/dev/null); then
    printf 'NETWORK_CHECKS: no temporary file could be created under %s, so %s never ran; fix TMPDIR and rerun %s/bin/cs-startup-network.sh run --locked %s\n' \
      "${TMPDIR:-/tmp}" "$(phase_label "$phases")" "$CS_ROOT" "$sweep_locked"
    return 1
  fi
  # Ask this pass to record where it spends its time. Recorded into a temp file
  # for the same reason the output is: a killed run must not leave a half-written
  # artifact where the previous run's complete one was. Recording is best-effort -
  # a temp file that cannot be created leaves the checks uninstrumented rather
  # than unrun.
  if timings=$(mktemp "${TMPDIR:-/tmp}/cs-startup-network-timings.XXXXXX" 2>/dev/null); then
    cs_timing_begin "$timings" || timings=
  else
    timings=
  fi
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
    0) publish "$generation" 'done' "$phases" "$sweep_locked" "$started" "$rc" "$out" "$timings" ;;
    "$CS_TIMEOUT_UNAVAILABLE")
      printf 'NETWORK_CHECKS: the runtime bound could not be established, so %s never ran; fix TMPDIR and rerun %s/bin/cs-startup-network.sh run --locked %s\n' \
        "$(phase_label "$phases")" "$CS_ROOT" "$sweep_locked" >> "$out"
      publish "$generation" failed "$phases" "$sweep_locked" "$started" "$rc" "$out" "$timings"
      ;;
    124)
      printf 'NETWORK_CHECKS: hit the %ss bound before finishing, so %s may be incomplete; rerun %s/bin/cs-startup-network.sh run --locked %s\n' \
        "$budget" "$(phase_label "$phases")" "$CS_ROOT" "$sweep_locked" >> "$out"
      publish "$generation" timeout "$phases" "$sweep_locked" "$started" "$rc" "$out" "$timings"
      ;;
    *)
      printf 'NETWORK_CHECKS: the deferred check worker exited %s, so %s may be incomplete; rerun %s/bin/cs-startup-network.sh run --locked %s\n' \
        "$rc" "$(phase_label "$phases")" "$CS_ROOT" "$sweep_locked" >> "$out"
      publish "$generation" failed "$phases" "$sweep_locked" "$started" "$rc" "$out" "$timings"
      ;;
  esac
  rm -f "$out" 2>/dev/null || true
  [ -z "$timings" ] || rm -f "$timings" 2>/dev/null || true
  return 0
}

# --- harvest / report --------------------------------------------------------

# Which check this run leaves uncovered and how to cover it, named the same plain
# way the read-only branch of bin/cs-session-start.sh names the checks it skipped
# rather than left for the reader to notice that a phase label never mentions it.
#
# The line states only that FACT. Two different paths reach here - adopting a
# narrower live pass, and a detached worker downgraded when the fleet lock
# changed hands - and no single sentence is true of both, so the reason stays
# with the NETWORK_CHECKS line in the result body, which states the accurate one
# for whichever path this was.
print_uncovered() {
  local uncovered
  uncovered=$(uncovered_label "$(status_get phases)" "$(status_get requested)")
  [ -n "$uncovered" ] || return 0
  printf 'NOT covered by this run: %s.\n' "$uncovered"
  printf 'Cover it with %s/bin/cs-startup-network.sh run --locked 1.\n' "$CS_ROOT"
}

# The --locked value a rerun needs to cover everything the session asked for.
#
# A pass reached through adoption or downgrade records the NARROWER `locked` it
# actually ran with, so echoing that back names a probe-only rerun that provably
# cannot cover the missing sweep - worse than naming nothing, because it reads as
# a remedy and is not. What the session asked for is what a rerun has to satisfy.
rerun_locked() {
  case "$(status_get requested)" in
    *sweeps*) printf '1' ; return 0 ;;
  esac
  case "$(status_get locked)" in
    1) printf '1' ;;
    *) printf '0' ;;
  esac
}

# Results that finished and were never read, oldest first, each labelled with the
# coverage it speaks for. Printed ahead of the current result because they are
# older than it, and drained by the harvest that prints them.
print_pending_store() {
  local entry name dropped
  for name in $(pending_names); do
    entry="$PENDING_DIR/$name"
    [ -f "$entry" ] || continue
    printf 'Finished earlier and never read - that run covered: %s.\n' \
      "$(phase_label "$(result_covered "$entry")")"
    result_body "$entry"
  done
  dropped=$(cat "$DROPPED_FILE" 2>/dev/null || true)
  case "$dropped" in
    ''|*[!0-9]*|0) ;;
    *) printf '(%s more unread earlier results - the store keeps the %s most recent, so re-derive those findings with %s/bin/cs-startup-network.sh run --locked 1)\n' \
        "$dropped" "$STARTUP_NETWORK_PENDING_MAX" "$CS_ROOT" ;;
  esac
}

# The current result when it is one nothing has read yet and no other branch is
# about to print it: a record left running or a publish that could not land keeps
# the previous result in place, and it stays reachable through the same reader
# the wake that announced it names.
print_outstanding() {
  result_unread || return 0
  printf 'Finished earlier and never read - that run covered: %s.\n' \
    "$(phase_label "$(result_covered "$REPORT_FILE")")"
  result_body "$REPORT_FILE"
}

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
      "$(phase_label "$phases")" "$CS_ROOT" "$(rerun_locked)"
    print_outstanding
  elif result_has_body "$REPORT_FILE"; then
    result_body "$REPORT_FILE"
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
  printf 'Read it now with %s/bin/cs-startup-network.sh read; until it lands, treat none of it as confirmed.\n' "$CS_ROOT"
  print_outstanding
}

# The gap disclosure is emitted HERE, once, rather than by each branch: a reader
# path that forgets it hides exactly what the session asked for and never got,
# and that is what happened while three branches each carried their own call.
# One call site means every branch, including any added later, discloses.
print_state() {
  print_pending_store
  case "$(status_get state)" in
    done|timeout|failed) print_finished "$(status_get state)" ;;
    running)
      if worker_alive; then
        print_pending
      else
        printf 'NETWORK_CHECKS: the deferred check worker stopped before publishing, so %s did not complete; rerun %s/bin/cs-startup-network.sh run --locked %s\n' \
          "$(phase_label "$(status_get phases)")" "$CS_ROOT" "$(rerun_locked)"
        print_outstanding
      fi
      ;;
    *) printf 'not started - no deferred network checks have run for this home yet.\n' ;;
  esac
  print_uncovered
}

# Where the last published pass spent its time. Deliberately NOT part of
# print_state: print_state is what composes the digest's NETWORK CHECKS section
# and what the wake reader prints, and a timeline is operator material rather
# than something the agent has to act on. Keeping it out of that function is what
# makes "harvest is byte-for-byte unchanged" a property of the code rather than a
# claim about how it is called.
print_timings() {
  [ -s "$TIMINGS_FILE" ] || return 0
  printf 'Where this stage spent its time, offsets from one shared origin:\n'
  cs_timing_print "$TIMINGS_FILE" || true
}

# Did print_state print the CURRENT result? A terminal record that published one
# always prints it, INCLUDING the empty-bodied result of a clean run, whose
# "(silent - no problems found)" line is that result being delivered rather than
# a reason to withhold the acknowledgement - withholding it there would queue a
# redundant wake on the healthiest and commonest path there is. Otherwise the
# current result is shown exactly when print_outstanding showed the unread one
# still sitting in place.
current_result_shown() {
  case "$(status_get state)" in
    done|timeout|failed)
      [ "$(status_get report_published)" = 0 ] || return 0
      ;;
  esac
  result_unread
}

# Print, then acknowledge exactly what was printed, both under the publish lock.
# Deciding BEFORE printing is what keeps the two in step: the acknowledgement can
# never claim more than print_state actually showed. Draining the store is the
# other half of that same act, and it is what leaves the next publish with
# nothing to pend, so a result already read cannot come back as an unread one.
print_and_acknowledge() {
  local deliver=0
  ! current_result_shown || deliver=1
  print_state
  rm -rf "$PENDING_DIR" 2>/dev/null || true
  [ "$deliver" -eq 0 ] || write_atomic "$DELIVERED_FILE" <<EOF || true
delivered
EOF
}

cmd_harvest() {  # <pid>
  local pid=$1 generation claim_record claim_generation claim_pid
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
  print_and_acknowledge
  cs_lock_release "$PUBLISH_LOCK"
}

# The reader the wake names. It differs from harvest in one thing: it touches no
# claim, because an agent following a wake is not the session start that
# registered one, and reaping a live claimant's claim would cost that session its
# inline print.
cmd_read() {
  cs_lock_acquire_wait "$PUBLISH_LOCK"
  print_and_acknowledge
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
# check as pending that nothing is going to run. The three readers are reporting
# commands and always exit 0.
RC=0
case "$MODE" in
  start) cmd_start "$LOCKED" "${HARVEST_PID:-0}" || RC=$? ;;
  run) cmd_run "$LOCKED" "$LOCK_PID" "$GENERATION" || RC=$? ;;
  harvest) cmd_harvest "${HARVEST_PID:-}" ;;
  read) cmd_read ;;
  report) print_state; print_timings ;;
  wait) cmd_wait "${1:-120}" || RC=$? ;;
  -h|--help) usage ;;
  *)
    printf 'cs-startup-network: unknown mode: %s\n' "${MODE:-<none>}" >&2
    printf 'usage: cs-startup-network.sh start|run|harvest|read|report|wait\n' >&2
    exit 2
    ;;
esac
exit "$RC"
