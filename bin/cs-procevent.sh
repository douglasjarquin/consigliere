#!/usr/bin/env bash
# Process-event runner: supervise a registered BLOCKING child outside the
# agent's conversational turn and turn its completed output into a normalized
# durable wake.
#
# Usage:
#   cs-procevent.sh register <adapter> <source-id> -- <argv>...
#   cs-procevent.sh start <source-id>
#   cs-procevent.sh reconcile
#   cs-procevent.sh handled <source-id> <sequence>
#   cs-procevent.sh retire <source-id>
#   cs-procevent.sh retire-home
#
# register    Record a source: its adapter, its canonical id, and the exact argv
#             to execute. argv is stored one argument per line and executed
#             directly, so there is no shell surface and no argument splitting.
#             Adapters register sources; nothing here parses user text.
# start       Claim the source, run its child to completion, durably capture the
#             output, publish a wake for every pending result, then release the
#             claim. It blocks as long as the source blocks and is meant to run
#             as a supervised background process, never in a turn. After
#             publishing it asks the source's own adapter whether the captured
#             result ends the source, and retires the registration when it says
#             so, so an ended source stops being restarted.
# reconcile   Idempotent liveness entry the watcher calls each cycle: republish
#             every captured result with no handled acknowledgement yet, and
#             start a runner for any registered source with no live owner. This
#             is liveness repair only; it never polls the source, because the
#             child blocks on the source itself.
# handled     Durably and idempotently record that a captured result has been
#             fully handled. Prints "handled: <id> <seq>" the first time for that
#             exact generation and "already-handled: <id> <seq>" on every repeat,
#             atomically deduplicated. Refuses unless the matching result and
#             adapter records exist, so a premature call cannot suppress a future
#             result. Until this is called the result stays eligible for
#             re-announcement on every reconcile.
# retire      Drop a registration, stop a runner this home owns, release the
#             claim. Idempotent, and still the explicit path after a source has
#             already retired itself on its adapter's terminal verdict.
# retire-home Bounded retire of every registration and every claim this home
#             owns, then refuse unless nothing is left. Home retirement calls it
#             before removing a home, because a leaked blocking child against a
#             shared external source is real harm.
#
# Terminal knowledge is adapter-owned. This runner never inspects a result and
# never names an adapter-specific status: it calls
# `bin/cs-procevent-<adapter>.sh terminal <result-file>` and treats exit 0 as the
# only terminal verdict. A missing command, an error, or any other exit keeps the
# registration armed, so an adapter with no notion of ending needs no change.
#
# Silence is adapter-owned the same way. It calls
# `bin/cs-procevent-<adapter>.sh silent <result-file>` and treats exit 0 as the
# only silence verdict. A result its adapter declares a routine no-op is recorded
# handled and never announced, so it neither wakes a handler now nor comes back
# on a later reconcile. A missing command, an error, or any other exit publishes
# the wake unchanged.
#
# Ownership is machine-wide per canonical source, because a main home and its
# capo homes share one machine and one source store. A live owner is never
# displaced; only a claim whose whole generation is gone is reclaimed. A runner
# leads its own process group, so a crashed leader whose group still has members
# is NOT stale: reconcile stops that surviving group and releases its generation
# before any replacement starts, and keeps the claim for a later retry when it
# cannot prove the group stopped.
#
# Durability boundary: see bin/cs-procevent-lib.sh. This proves capture before
# publication and re-announcement until handled, and nothing about the source
# side of the handoff.
#
# Environment: CS_PROCEVENT_CLAIM_ROOT overrides the machine-wide claim root;
# CS_PROCEVENT_MAX_OUTPUT_BYTES bounds one captured result (default 1048576).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
# shellcheck source=bin/cs-pr-lib.sh
. "$SCRIPT_DIR/cs-pr-lib.sh"
# shellcheck source=bin/cs-wake-lib.sh
. "$SCRIPT_DIR/cs-wake-lib.sh"
# shellcheck source=bin/cs-procevent-lib.sh
. "$SCRIPT_DIR/cs-procevent-lib.sh"

REG=$(cs_procevent_registry_dir "$STATE")
MAX_OUTPUT_BYTES=${CS_PROCEVENT_MAX_OUTPUT_BYTES:-1048576}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
  exit 2
}

adapter_script() { printf '%s/bin/cs-procevent-%s.sh\n' "$CS_ROOT" "$1"; }

# Ask the source's own adapter whether a captured result ends the source. Exit 0
# is the only terminal verdict; everything else - including a missing adapter
# command - keeps the registration armed.
adapter_result_is_terminal() {  # <adapter> <result-file>
  local script
  script=$(adapter_script "$1")
  [ -f "$script" ] && [ ! -L "$script" ] || return 1
  "$script" terminal "$2" >/dev/null 2>&1
}

# Ask the source's own adapter whether a captured result is a routine no-op that
# needs no wake at all. Exit 0 is the only silence verdict; everything else -
# including a missing adapter command - publishes the wake.
adapter_result_is_silent() {  # <adapter> <result-file>
  local script
  script=$(adapter_script "$1")
  [ -f "$script" ] && [ ! -L "$script" ] || return 1
  "$script" silent "$2" >/dev/null 2>&1
}

source_file()  { printf '%s/%s.source\n' "$REG" "$1"; }
runner_file()  { printf '%s/%s.runner\n' "$REG" "$1"; }
staging_file() { printf '%s/.%s.%s.output\n' "$REG" "$1" "$2"; }

read_adapter() {  # <source-id>
  local f; f=$(source_file "$1")
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  sed -n 's/^adapter=//p' "$f" | head -1
}

# Read the stored argv into ARGV. One argument per line after the argc= count,
# so an argument containing spaces is never re-split.
read_argv() {  # <source-id>
  local f n i=0 line; f=$(source_file "$1")
  ARGV=()
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  n=$(sed -n 's/^argc=//p' "$f" | head -1)
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  while IFS= read -r line; do
    i=$((i + 1))
    [ "$i" -le "$n" ] && ARGV+=("$line")
  done < <(sed -n '/^argv:$/,$p' "$f" | tail -n +2)
  [ "${#ARGV[@]}" -eq "$n" ]
}

cmd_register() {
  local adapter=${1-} id=${2-} sep=${3-} arg tmp dest
  shift 3 2>/dev/null || usage
  cs_procevent_adapter_valid "$adapter" || die "adapter name must be lowercase alphanumeric or dash: $adapter"
  cs_procevent_source_id_valid "$id" || die "source id must be path-safe and at most 64 characters: $id"
  [ "$sep" = -- ] || usage
  [ "$#" -ge 1 ] || die "register needs at least one argv element after --"
  for arg in "$@"; do
    case "$arg" in *$'\n'*) die "argv elements cannot contain newlines" ;; esac
  done
  [ -f "$(adapter_script "$adapter")" ] || die "no installed adapter for: $adapter"
  (umask 077; mkdir -p "$REG") || die "cannot create the source registry"
  dest=$(source_file "$id")
  tmp=$(umask 077; mktemp "$REG/.source.XXXXXX") || die "cannot stage the registration"
  {
    printf 'adapter=%s\n' "$adapter"
    printf 'argc=%s\n' "$#"
    printf 'argv:\n'
    printf '%s\n' "$@"
  } > "$tmp" || { rm -f -- "$tmp"; die "cannot write the registration"; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; die "cannot secure the registration"; }
  cs_procevent_source_lock_acquire "$id" || { rm -f -- "$tmp"; die "cannot lock the source"; }
  if ! mv -f -- "$tmp" "$dest"; then
    cs_procevent_source_lock_release "$id"
    rm -f -- "$tmp"
    die "cannot publish the registration"
  fi
  cs_procevent_source_lock_release "$id"
  printf 'registered: %s (%s)\n' "$id" "$adapter"
}

# Publish one captured result with no handled acknowledgement yet. Capture has
# already happened, so this only turns durable state into durable events, and it
# republishes on every call regardless of any earlier publication unless the
# adapter declares the result a routine no-op. The wake line carries IDENTITY
# ONLY - never a byte of source output.
publish_result() {  # <result-file>
  local result=$1 id seq adapter line status=1 mark_status
  id=$(cs_procevent_result_source_id "$result")
  seq=$(cs_procevent_result_sequence "$result")
  cs_procevent_source_id_valid "$id" || return 1
  adapter=$(cs_procevent_result_adapter "$result" 2>/dev/null || true)
  [ -n "$adapter" ] || return 1
  line=$(cs_procevent_event_line "$adapter" "$id" "$seq") || return 1
  cs_procevent_source_lock_acquire "$id" || return 1
  if ! cs_procevent_is_handled "$STATE" "$id" "$seq"; then
    if adapter_result_is_silent "$adapter" "$result"; then
      cs_procevent_mark_handled "$STATE" "$id" "$seq"
      mark_status=$?
      case "$mark_status" in
        0|1)
          cs_procevent_source_lock_release "$id"
          return 1
          ;;
      esac
    fi
    if cs_wake_append check "procevent:$id:$seq" "check: $line"; then
      status=0
    fi
  fi
  cs_procevent_source_lock_release "$id"
  return "$status"
}

publish_pending() {
  local result published=0
  while IFS= read -r result; do
    [ -n "$result" ] || continue
    if publish_result "$result"; then
      published=$((published + 1))
    fi
  done < <(cs_procevent_pending "$STATE")
  printf '%s\n' "$published"
}

# Re-exec the runner as its own process-group LEADER and start the blocking child
# inside that group. A watcher-style timeout kill is not enough: signalling only
# the runner would leave the blocking child alive and reparented, which is
# exactly how a source that never completes leaks.
isolate_runner() {  # <wait|detach> <source-id>
  local mode=$1 id=$2 program
  # shellcheck disable=SC2016 # Perl owns every $ expression in this literal program.
  program='my $mode = shift @ARGV;
    defined(my $pid = fork) or exit 125;
    if ($pid == 0) {
      setpgrp(0, 0) or exit 125;
      $ENV{CS_PROCEVENT_RUNNER_GROUP} = $$;
      exec @ARGV;
      exit 125;
    }
    exit 0 if $mode eq "detach";
    waitpid($pid, 0) == $pid or exit 125;
    my $status = $?;
    exit(128 + ($status & 127)) if $status & 127;
    exit($status >> 8);'
  if [ "$mode" = wait ]; then
    exec perl -e "$program" "$mode" "$SCRIPT_DIR/cs-procevent.sh" _start "$id"
  fi
  perl -e "$program" "$mode" "$SCRIPT_DIR/cs-procevent.sh" _start "$id" >/dev/null 2>&1 &
}

require_runner_group() {
  local pgid
  [ "${CS_PROCEVENT_RUNNER_GROUP:-}" = "$$" ] \
    || die "runner process group was not isolated"
  pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]') \
    || die "cannot inspect runner process group"
  [ "$pgid" = "$$" ] || die "runner does not lead its process group"
  unset CS_PROCEVENT_RUNNER_GROUP
}

cmd_start_public() {
  local id=${1-}
  [ "$#" -eq 1 ] || usage
  cs_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  isolate_runner wait "$id"
}

release_start_claim() {
  [ -z "$STAGED_OUTPUT" ] || rm -f -- "$STAGED_OUTPUT"
  cs_procevent_source_lock_acquire "$CLAIM_ID" 2>/dev/null || return 0
  # A generation already flipped to `terminal` is being unregistered by the
  # retirement path; releasing it here would race that transition.
  if cs_procevent_claim_load_locked "$CLAIM_ID" 2>/dev/null \
    && [ "$CS_PROCEVENT_CLAIM_HOME" = "$CLAIM_HOME" ] \
    && [ "$CS_PROCEVENT_CLAIM_PID" = "$CLAIM_PID" ] \
    && [ "$CS_PROCEVENT_CLAIM_TOKEN" = "$CLAIM_TOKEN" ] \
    && [ "$CS_PROCEVENT_CLAIM_TERMINAL" = terminal ]; then
    cs_procevent_source_lock_release "$CLAIM_ID" 2>/dev/null || true
    return 0
  fi
  cs_procevent_claim_release_locked "$CLAIM_ID" "$CLAIM_HOME" "$CLAIM_PID" "$CLAIM_TOKEN" 2>/dev/null || true
  cs_procevent_source_lock_release "$CLAIM_ID" 2>/dev/null || true
}

# Retire a source this runner owns because its adapter classified the captured
# result terminal. Ownership is re-proved, the registration is dropped, and this
# runner's own claim is released under ONE source-lock hold, so no concurrent
# reconcile can see a registered source with no owner (and start a replacement)
# or an owned claim with no registration (and signal this runner mid-exit).
retire_owned_terminal_source() {  # <source-id>
  local id=$1 status=0 registration current_identity
  registration=$(source_file "$id")
  cs_procevent_source_lock_acquire "$id" || return 1
  if cs_procevent_claim_load_locked "$id" 2>/dev/null \
    && [ "$CS_PROCEVENT_CLAIM_HOME" = "$CLAIM_HOME" ] \
    && [ "$CS_PROCEVENT_CLAIM_PID" = "$CLAIM_PID" ] \
    && [ "$CS_PROCEVENT_CLAIM_TOKEN" = "$CLAIM_TOKEN" ] \
    && [ "$CS_PROCEVENT_CLAIM_REG_IDENTITY" = "$CLAIM_REG_IDENTITY" ] \
    && current_identity=$(cs_pr_file_identity "$registration" 2>/dev/null) \
    && [ "$current_identity" = "$CLAIM_REG_IDENTITY" ] \
    && cs_procevent_claim_mark_terminal_locked "$id" "$CLAIM_HOME" "$CLAIM_PID" "$CLAIM_TOKEN"; then
    if rm -f -- "$registration" && [ ! -e "$registration" ] && [ ! -L "$registration" ]; then
      cs_procevent_claim_release_locked "$id" "$CLAIM_HOME" "$CLAIM_PID" "$CLAIM_TOKEN" || status=1
    else
      status=1
    fi
  else
    status=1
  fi
  cs_procevent_source_lock_release "$id"
  return "$status"
}

cmd_start() {
  local id=${1-} adapter out rc size truncated=0 claimed durable
  cs_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  require_runner_group
  case "$MAX_OUTPUT_BYTES" in
    ''|*[!0-9]*|0) die "CS_PROCEVENT_MAX_OUTPUT_BYTES must be a positive integer" ;;
  esac
  cs_procevent_source_lock_acquire "$id" || die "cannot lock source: $id"
  if [ ! -f "$(source_file "$id")" ] || [ -L "$(source_file "$id")" ]; then
    cs_procevent_source_lock_release "$id"
    die "source is not registered: $id"
  fi
  if ! adapter=$(read_adapter "$id") || ! cs_procevent_adapter_valid "$adapter" || ! read_argv "$id"; then
    cs_procevent_source_lock_release "$id"
    die "registration is unreadable: $id"
  fi
  cs_procevent_claim_acquire_locked "$id" "$CS_HOME" "$$" "$(source_file "$id")"
  claimed=$?
  cs_procevent_source_lock_release "$id"
  case "$claimed" in
    0) ;;
    2) printf 'already owned: %s\n' "$id"; exit 0 ;;
    *) die "cannot claim source: $id" ;;
  esac
  CLAIM_ID=$id
  CLAIM_HOME=$CS_HOME
  CLAIM_PID=$$
  CLAIM_TOKEN=$CS_PROCEVENT_CLAIM_TOKEN
  CLAIM_REG_IDENTITY=$CS_PROCEVENT_CLAIM_REG_IDENTITY
  STAGED_OUTPUT=
  trap release_start_claim EXIT
  printf '%s\n' "$$" > "$(runner_file "$id")" 2>/dev/null || true
  chmod 0600 "$(runner_file "$id")" 2>/dev/null || true

  out=$(staging_file "$id" "$CLAIM_TOKEN")
  [ ! -e "$out" ] && [ ! -L "$out" ] || die "cannot safely stage output"
  (umask 077; : > "$out") || die "cannot stage output"
  STAGED_OUTPUT=$out

  # Bound the captured bytes. Unbounded capture into state/ is a real hazard, and
  # `head -c` is the simplest bound that works on both hosted platforms: it stops
  # reading at the cap, so an over-talkative source is truncated rather than
  # allowed to fill the home. A truncated capture is still a real result.
  "${ARGV[@]}" 2>/dev/null | head -c "$MAX_OUTPUT_BYTES" > "$out"
  rc=${PIPESTATUS[0]}
  size=$(wc -c < "$out" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  [ "$size" -lt "$MAX_OUTPUT_BYTES" ] || truncated=1

  if [ "$rc" -ne 0 ] && [ "$size" -eq 0 ]; then
    # No usable result. Leave the registration armed; the adapter decides whether
    # a nonzero exit is terminal when it classifies the next real result.
    rm -f -- "$out" "$(runner_file "$id")"
    STAGED_OUTPUT=
    printf 'no-result: %s (exit %s)\n' "$id" "$rc"
    exit 0
  fi

  durable=$(cs_procevent_capture "$STATE" "$id" "$adapter" "$out") \
    || { rm -f -- "$out"; die "cannot durably capture the result"; }
  rm -f -- "$out"
  STAGED_OUTPUT=
  [ "$truncated" -eq 0 ] || printf 'truncated: %s at %s bytes\n' "$id" "$MAX_OUTPUT_BYTES" >&2

  publish_pending >/dev/null
  rm -f -- "$(runner_file "$id")"
  # Publication is already durable, so retiring an ended source here can never
  # cost the result or its wake; leaving it armed, by contrast, lets every later
  # reconcile restart a source that will only ever return empty ended results.
  if adapter_result_is_terminal "$adapter" "$durable"; then
    if retire_owned_terminal_source "$id"; then
      printf 'retired: %s (adapter classified the captured result terminal)\n' "$id"
    else
      printf 'cannot retire terminal source; it remains registered: %s\n' "$id" >&2
    fi
  fi
  printf 'captured: %s\n' "$durable"
}

detach_runner() {  # <source-id>
  isolate_runner detach "$1"
}

# Stop a runner and the child it is blocked on. A runner leads its own process
# group, so the GROUP signal is what actually reaches the blocking child.
# 0 stopped, 1 already gone, 2 could not be proved.
stop_runner_pid() {  # <pid> <identity>
  local pid=${1-} identity=${2-} state pgid i=0
  case "$pid" in ''|*[!0-9]*) return 2 ;; esac
  [ -n "$identity" ] || return 2
  cs_procevent_pid_state "$pid" "$identity"
  state=$?
  case "$state" in
    0)
      # A live identity-matched leader still owns its group, so prove the group
      # really is the one this pid leads before signalling it.
      pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]') || return 2
      [ "$pgid" = "$pid" ] || return 2
      ;;
    3)
      # The leader crashed but its owned group is still running. Its pgid cannot
      # be read from the dead leader and does not need to be: only an ABSENT
      # leader reaches this state, so the group cannot belong to a reused pid.
      ;;
    *) return "$state" ;;
  esac
  kill -TERM -"$pid" 2>/dev/null || return 2
  while [ "$i" -lt 20 ]; do
    kill -0 -"$pid" 2>/dev/null || return 0
    if kill -0 "$pid" 2>/dev/null; then
      cs_procevent_pid_state "$pid" "$identity"
      state=$?
      [ "$state" -eq 2 ] && return 2
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill -KILL -"$pid" 2>/dev/null || return 2
  i=0
  while [ "$i" -lt 20 ]; do
    kill -0 -"$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 2
}

# Stop a runner this home owns whose source is no longer registered. Without
# this, unregistering a source that never completes leaves its child blocked
# forever with nothing left to reap it.
reconcile_orphan_claims() {
  local claim id
  for claim in "$(cs_procevent_claim_root)"/*.claim; do
    [ -e "$claim" ] || continue
    id=${claim##*/}; id=${id%.claim}
    cs_procevent_source_id_valid "$id" || continue
    cs_procevent_source_lock_acquire "$id" || continue
    if [ -f "$(source_file "$id")" ] && [ ! -L "$(source_file "$id")" ]; then
      cs_procevent_source_lock_release "$id"
      continue
    fi
    if ! cs_procevent_claim_load_locked "$id" 2>/dev/null; then
      UNCERTAIN=$((UNCERTAIN + 1))
      cs_procevent_source_lock_release "$id"
      continue
    fi
    if [ "$CS_PROCEVENT_CLAIM_HOME" != "$CS_HOME" ]; then
      cs_procevent_source_lock_release "$id"
      continue
    fi
    release_generation "$id" "$CS_PROCEVENT_CLAIM_HOME" "$CS_PROCEVENT_CLAIM_PID" \
      "$CS_PROCEVENT_CLAIM_TOKEN" "$CS_PROCEVENT_CLAIM_IDENTITY" 1 || true
    cs_procevent_source_lock_release "$id"
  done
}

# Stop a generation's process group and release its claim, under a lock the
# caller already holds. <allow-already-gone> 1 accepts a generation that was
# already gone. Increments STOPPED or UNCERTAIN; returns 0 only when the
# generation is provably released.
release_generation() {  # <id> <home> <pid> <token> <identity> <allow-already-gone>
  local id=$1 home=$2 pid=$3 token=$4 identity=$5 allow_gone=$6 stop_state
  stop_runner_pid "$pid" "$identity"
  stop_state=$?
  if [ "$stop_state" -ne 0 ] && { [ "$allow_gone" -ne 1 ] || [ "$stop_state" -ne 1 ]; }; then
    UNCERTAIN=$((UNCERTAIN + 1))
    return 1
  fi
  if cs_procevent_claim_release_locked "$id" "$home" "$pid" "$token" 2>/dev/null; then
    rm -f -- "$(staging_file "$id" "$token")" "$(runner_file "$id")"
    STOPPED=$((STOPPED + 1))
    return 0
  fi
  UNCERTAIN=$((UNCERTAIN + 1))
  return 1
}

# One registered source: start a replacement only when no live generation owns
# it, and never alongside a surviving process group.
reconcile_one_source() {  # <source-id>
  local id=$1 claim_state home pid token identity
  cs_procevent_claim_state_locked "$id"
  claim_state=$?
  case "$claim_state" in
    1)
      cs_procevent_source_lock_release "$id"
      detach_runner "$id"
      STARTED=$((STARTED + 1))
      return 0
      ;;
    4)
      # The owning runner already classified this source terminal; finish its
      # retirement instead of restarting it.
      home=$CS_PROCEVENT_CLAIM_HOME
      pid=$CS_PROCEVENT_CLAIM_PID
      token=$CS_PROCEVENT_CLAIM_TOKEN
      if [ "$home" = "$CS_HOME" ] \
        && rm -f -- "$(source_file "$id")" \
        && [ ! -e "$(source_file "$id")" ] && [ ! -L "$(source_file "$id")" ] \
        && cs_procevent_claim_release_locked "$id" "$home" "$pid" "$token" 2>/dev/null; then
        STOPPED=$((STOPPED + 1))
      else
        UNCERTAIN=$((UNCERTAIN + 1))
      fi
      ;;
    3)
      # The leader crashed but its owned group is still consuming the source.
      # Never start a replacement alongside it: stop that group and release its
      # generation first, and if either cannot be proved, KEEP the claim and
      # retry on a later cycle rather than adding a second destructive poller.
      # Only the owning home may signal its own group.
      home=$CS_PROCEVENT_CLAIM_HOME
      pid=$CS_PROCEVENT_CLAIM_PID
      token=$CS_PROCEVENT_CLAIM_TOKEN
      identity=$CS_PROCEVENT_CLAIM_IDENTITY
      if [ "$home" != "$CS_HOME" ]; then
        UNCERTAIN=$((UNCERTAIN + 1))
      elif release_generation "$id" "$home" "$pid" "$token" "$identity" 0; then
        cs_procevent_source_lock_release "$id"
        detach_runner "$id"
        STARTED=$((STARTED + 1))
        return 0
      fi
      ;;
    2) UNCERTAIN=$((UNCERTAIN + 1)) ;;
  esac
  cs_procevent_source_lock_release "$id"
}

cmd_reconcile() {
  local rec id published
  STARTED=0; STOPPED=0; UNCERTAIN=0
  published=$(publish_pending)
  reconcile_orphan_claims
  if [ -d "$REG" ]; then
    for rec in "$REG"/*.source; do
      [ -e "$rec" ] || continue
      id=${rec##*/}; id=${id%.source}
      cs_procevent_source_id_valid "$id" || continue
      cs_procevent_source_lock_acquire "$id" || continue
      if [ -f "$(source_file "$id")" ] && [ ! -L "$(source_file "$id")" ]; then
        reconcile_one_source "$id"
      else
        cs_procevent_source_lock_release "$id"
      fi
    done
  fi
  printf 'reconciled: published=%s started=%s stopped=%s uncertain=%s\n' \
    "$published" "$STARTED" "$STOPPED" "$UNCERTAIN"
}

cmd_handled() {
  local id=${1-} seq=${2-} status
  cs_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer: $seq" ;; esac
  cs_procevent_source_lock_acquire "$id" || die "cannot lock source: $id"
  cs_procevent_mark_handled "$STATE" "$id" "$seq"
  status=$?
  cs_procevent_source_lock_release "$id"
  case "$status" in
    0) printf 'handled: %s %s\n' "$id" "$seq" ;;
    1) printf 'already-handled: %s %s\n' "$id" "$seq" ;;
    *) die "no captured result to acknowledge: $id $seq" ;;
  esac
}

cmd_retire() {
  local id=${1-} home pid token identity stop_state
  cs_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  cs_procevent_source_lock_acquire "$id" || die "cannot lock source: $id"
  if [ -e "$(cs_procevent_claim_path "$id")" ]; then
    if ! cs_procevent_claim_load_locked "$id" 2>/dev/null; then
      cs_procevent_source_lock_release "$id"
      die "cannot safely read source ownership: $id"
    fi
    if [ "$CS_PROCEVENT_CLAIM_HOME" = "$CS_HOME" ]; then
      home=$CS_PROCEVENT_CLAIM_HOME
      pid=$CS_PROCEVENT_CLAIM_PID
      token=$CS_PROCEVENT_CLAIM_TOKEN
      identity=$CS_PROCEVENT_CLAIM_IDENTITY
      stop_runner_pid "$pid" "$identity"
      stop_state=$?
      if [ "$stop_state" -eq 2 ]; then
        cs_procevent_source_lock_release "$id"
        die "cannot confirm runner identity; source remains registered: $id"
      fi
      if ! cs_procevent_claim_release_locked "$id" "$home" "$pid" "$token"; then
        cs_procevent_source_lock_release "$id"
        die "cannot release source ownership: $id"
      fi
      rm -f -- "$(staging_file "$id" "$token")"
    fi
  fi
  rm -f -- "$(source_file "$id")" "$(runner_file "$id")"
  cs_procevent_source_lock_release "$id"
  printf 'retired: %s\n' "$id"
}

# Every source id this home is responsible for: its registrations, its runner
# records, and any claim it owns. Printed one per line, deduplicated.
home_source_ids() {
  local path id owner
  {
    for path in "$REG"/*.source "$REG"/*.runner; do
      { [ -e "$path" ] || [ -L "$path" ]; } || continue
      id=${path##*/}; printf '%s\n' "${id%.*}"
    done
    for path in "$(cs_procevent_claim_root)"/*.claim; do
      [ -f "$path" ] && [ ! -L "$path" ] || continue
      IFS= read -r owner < "$path" 2>/dev/null || continue
      [ "$owner" = "$CS_HOME" ] || continue
      id=${path##*/}; printf '%s\n' "${id%.claim}"
    done
  } | LC_ALL=C sort -u
}

# Bounded retire of everything this home owns, then a refusal unless nothing is
# left. Home retirement calls this BEFORE removing the home, because a leaked
# blocking child against a shared external source is real harm.
cmd_retire_home() {
  local id attempted=0 failed=0 remaining=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    attempted=$((attempted + 1))
    # In a subshell so one source's refusal (`die`) fails only that retire and
    # the loop still reaches every remaining source.
    if ! cs_procevent_source_id_valid "$id" || ! ( cmd_retire "$id" ) >/dev/null; then
      failed=$((failed + 1))
    fi
  done < <(home_source_ids)
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    remaining=$((remaining + 1))
  done < <(home_source_ids)
  if [ "$failed" -ne 0 ] || [ "$remaining" -ne 0 ]; then
    printf 'error: process-event home retirement incomplete: attempted=%s failed=%s remaining=%s\n' \
      "$attempted" "$failed" "$remaining" >&2
    return 1
  fi
  printf 'retired-home: attempted=%s\n' "$attempted"
}

case "${1-}" in
  register)    shift; cmd_register "$@" ;;
  start)       shift; cmd_start_public "$@" ;;
  _start)      shift; cmd_start "$@" ;;
  reconcile)   shift; cmd_reconcile "$@" ;;
  handled)     shift; cmd_handled "$@" ;;
  retire)      shift; cmd_retire "$@" ;;
  retire-home) shift; cmd_retire_home "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
