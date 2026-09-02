#!/usr/bin/env bash
# cs-session-start.sh - one command for the whole session start.
#
# Produces ONE ordered digest so a session starts in one or two turns:
#   1. lock          - acquire the per-home session lock FIRST, before any
#                      mutating step runs (cs-lock.sh).
#   2. bootstrap     - the LOCAL detect-only diagnostics always run; the local
#                      mutating sweeps (capo fast-forward, capo liveness) run
#                      only when this session actually holds the lock
#                      (CS_BOOTSTRAP_DETECT_ONLY=1 otherwise). Its network half
#                      (the gh auth probe and the fleet sync) runs in the
#                      deferred stage started at step 1, never here
#                      (CS_BOOTSTRAP_NETWORK=skip on every path).
#   3. wake-drain    - mutates the durable wake queue, so it also only runs
#                      when locked; drained records are this turn's first work
#                      queue. The read-only path leaves the queue untouched
#                      and runs cs-guard.sh in advisory mode instead.
#   4. supervision   - the ONE foreground-checkpoint operating block, inlined
#                      here (the protocol is identical across harnesses and
#                      one wait shape; there is no protocol renderer).
#   5. read-once     - the do-not-re-read contract covering every source
#                      represented by the two digests below, stated once,
#                      ahead of the payload it governs.
#   6. fleet state   - every state/*.meta with a cheap endpoint liveness read
#                      and bounded status tails (wake-EVENT history, not current
#                      state), orphan status logs, then the compact backlog
#                      listing, the standing board sweeps, and the afk flag. The
#                      live-task inventory leads the section for the same reason
#                      the section leads CONTEXT (see ORDERING below): it is
#                      what recovery depends on, so nothing else in the digest
#                      may sit between it and the top. The board sweep block
#                      also converges polls to records when locked
#                      (cs-board-watch.sh sync), so a sweep the boss started in
#                      an earlier session survives a wiped state/ or an
#                      interrupted arm instead of going quiet.
#   7. network checks - the result of the deferred network stage started back at
#                      step 1, harvested WITHOUT waiting for it.
#   8. context       - config/projects.md, host/capos.md, config/boss.md,
#                      config/boss-shared.md, config/learnings.md, each with an
#                      explicit ABSENT marker when missing (absence is
#                      meaningful and never confused with empty-but-present).
#                      The three curated startup-memory files also report when
#                      they exceed CS_STARTUP_MEMORY_MAX_BYTES, since every
#                      session of the home pays their cost; /vault consolidates.
#   9. next step     - points back at the supervision block; this script never
#                      starts supervision itself.
#
# NO NETWORK ON THE BLOCKING PATH. This digest runs on a session-open hook that
# blocks session initialization, so anything it waits for is time the boss waits
# before the first turn - and every external-network call it used to make was
# individually unbounded. One unreachable remote could burn the entire
# CS_SESSION_START_TIMEOUT and truncate the digest, so a slow network could cost
# the work queue itself. So no step between here and the last line below makes
# an external-network call. The two that did - `gh auth status` and the
# fleet-sync fetch of every project clone - are started as one detached bounded
# worker right after the lock (step 1) and harvested at step 7 without ever
# blocking on it. bin/cs-startup-network.sh owns that stage and its safety
# argument; bin/cs-bootstrap.sh remains the owner of the sweeps themselves and
# still runs every one of them. The capo sweeps stay here because they are
# local: a capo home is a detached worktree of this repo on this machine and its
# liveness probe asks the local herdr server.
# What this deliberately trades: on a slow network the digest prints IN PROGRESS
# and names exactly which checks are not yet confirmed, instead of waiting for
# them. It never reports an unconfirmed check as passed.
#
# ORDERING, and why FLEET STATE runs before CONTEXT: this digest is delivered
# through a harness that truncates an oversized payload from the TAIL, and it
# has really been truncated upstream - a 70KB digest arrived as lines 1-435 of
# 578, cutting off eight lines before the live-task inventory. What a truncated
# tail drops must therefore be the CHEAPEST thing to lose. Curated memory is
# stable session to session, already reported against CS_STARTUP_MEMORY_MAX_BYTES,
# and recoverable with one targeted read; live fleet identity - which tasks
# exist, their worktrees, panes, and endpoint liveness - changes every session
# and is exactly what recovery depends on. So fleet state goes first and the
# memory files absorb the truncation. The read-once contract moves ahead of
# both for the same reason: a contract that only arrives after the payload it
# governs is the first thing a truncated digest loses, and it names the
# never-emitted-stage condition that voids it for sources that never printed.
# The LOCK/BOOTSTRAP/WAKE-QUEUE safety preamble keeps its order: it establishes
# mutation authority and this turn's work queue before anything else is read.
#
# COMPOSITION, NOT DUPLICATION: this script calls cs-lock.sh, cs-bootstrap.sh,
# cs-wake-drain.sh, and cs-startup-network.sh as real subprocesses and prints
# their real output; all sequencing/formatting logic added here stays local to
# this file.
#
# BACKLOG DIGEST: the startup listing is a RECOVERY input, not a reporting
# surface, so it carries what this turn can act on and nothing else.
#   - Done rows are never listed. Retained completion history belongs to the
#     reporting surfaces (bin/cs-fleet-view.sh, /the-books); at startup it is
#     pure weight.
#   - Every in-flight, held, and blocked row is listed IN FULL, with its
#     hold_kind/hold_reason and blocked_by, up to CS_SESSION_START_ACTIVE_LIMIT
#     rows per group, default 40. Those are the rows AGENTS.md sections 7 and 10
#     make actionable at startup, so they are shown whole rather than summarized
#     - but a pathological fleet may not spend the whole digest on them either,
#     because this section shares the payload with the live-task inventory above
#     it.
#   - Queued public-followup rows are the one group NO bound may touch, on
#     EITHER backend. They are delivery obligations the boss is already owed, so
#     a startup that hides one behind a row limit is worse than a long digest.
#     They print in full however many there are, and the manual path counts them
#     separately so its accounting stays exact.
#   - The plain queued (dispatchable-now) listing is bounded separately, by
#     CS_SESSION_START_QUEUED_LIMIT, default 20, so a deep queue costs a counter
#     rather than kilobytes.
#   - No bound ever drops rows silently: every group that hits its limit prints
#     an exact remainder count and the targeted follow-up that shows the rest,
#     which is also what the READ-ONCE CONTRACT sanctions going back to.
# When the tasks-axi backend is selected and available, the groups are the
# tool's own filters (`--state in_flight`, `--state held`, `--state queued
# --blocked`, `--state queued --kind public-followup`, and `tasks-axi ready`),
# so this script never reimplements task state; the groups can overlap, because
# an in-flight item that is also held appears under both. The obligations filter
# is its own group because no other one reaches them: `tasks-axi ready` counts
# only DELIVERY-ready obligations, so an obligation still in `intent` is absent
# from both ready[ and ready_public_followups, and a blocked one would otherwise
# appear only inside the bounded blocked group. When manual mode is selected, or
# tasks-axi is unavailable, only backlog section headings and item title lines
# print, and the groups are recognized from the title line's own
# hold/blocked-by/kind markers.
#
# STATUS TAILS: CS_SESSION_START_STATUS_TAIL bounds how many lines each task's
# tail prints, and bin/cs-line-cap-lib.sh bounds how long each of those lines
# may be. Both bounds are safe because the section prints every task's full
# status log path, and AGENTS.md section 7 treats a status line as a wake EVENT
# rather than current state - bin/cs-crew-state.sh owns current state.
#
# RUNTIME BOUND: the digest is executed by the session-open hooks (see
# bin/cs-sessionstart-run.sh), which block session initialization while it
# runs, so an unbounded digest is no longer merely slow - it can strand a whole
# session behind one hung subprocess. Every remaining step is local, but local
# is not the same as bounded: bootstrap's tool presence probes, the backlog
# listing, and the per-task endpoint reads are all unbounded subprocesses. So
# the whole digest still runs as ONE bounded child of this script
# (CS_SESSION_START_TIMEOUT, default 120s). The deferred network stage
# deliberately sits OUTSIDE that bound, in its own process group under its own
# aggregate deadline (CS_STARTUP_NETWORK_TIMEOUT), so a truncated digest neither
# waits for it nor orphans it unbounded.
# The child
# writes the digest straight to this script's stdout, so everything it emitted
# before the bound was hit is already delivered; the parent then prints a loud
# STARTUP TRUNCATED banner naming the stage that did not finish and the stages
# that were therefore never emitted, and still exits 0. That banner is the
# never-emitted-stage condition the READ-ONCE CONTRACT names as voiding its
# trust for the sources those stages would have printed. The child records its
# progress in CS_SESSION_START_STAGE_FILE, which is also the flag that tells a
# child it is the child - the parent never recurses. Bounded execution routes
# through bin/cs-timeout-lib.sh, so hosts without timeout, gtimeout, or perl
# still get the same hard bound from the pure-Bash watchdog. A host where that
# library cannot even establish the bound reports itself separately
# (CS_TIMEOUT_UNAVAILABLE), because a digest that never started must not be
# announced as a digest that stalled.
#
# Usage: cs-session-start.sh [--reemit]
#   Prints the full ordered digest to stdout and always exits 0: this is a
#   reporting command, not a gate. A lock refusal is reported as a loud banner
#   inline, never a silent failure that would make an agent skip the digest.
#
#   --reemit  This session ALREADY completed a full startup and has only lost
#             its context (a /clear or a compaction). Skip the mutating sweeps
#             startup already reconciled - the config/ layout migration and
#             bootstrap's mutating sweeps (fleet sync, capo fast-forward, capo
#             liveness; bootstrap runs CS_BOOTSTRAP_DETECT_ONLY=1 with
#             CS_BOOTSTRAP_LOCKED=1 so repair ownership stays with this
#             session, and the deferred network stage runs its read-only gh
#             auth probe alone) - and re-emit the rest.
#             The wake-queue drain is NOT
#             skipped: queued records arrived after startup and are this turn's
#             work, and the session that owns the lock is exactly the session
#             that must take them. Lock acquisition still runs, because
#             ownership must be re-verified rather than assumed: cs-lock.sh
#             already treats a lock this session's own harness holds as its
#             own, so the re-emit proceeds, while a lock another live session
#             took meanwhile still produces the ordinary read-only path.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REEMIT=0
for arg in "$@"; do
  case "$arg" in
    --reemit) REEMIT=1 ;;
    -h|--help)
      sed -n '2,/^set -u$/p' "$SCRIPT_DIR/cs-session-start.sh" | sed 's/^# \{0,1\}//; $d'
      exit 0
      ;;
    *)
      printf 'cs-session-start: unknown argument: %s\n' "$arg" >&2
      printf 'usage: cs-session-start.sh [--reemit]\n' >&2
      exit 2
      ;;
  esac
done

# --- 0. runtime bound --------------------------------------------------------
# The ordered stage list is the contract behind the truncation banner: the
# child names the stage it is entering, and the parent reports every stage
# after that one as never emitted. Keep it in the exact order the digest
# prints.
SESSION_START_STAGES='lock bootstrap wake-queue supervision read-once fleet-state network-checks context next-step'

stage() {  # <stage-name>: breadcrumb for the parent's truncation banner
  [ -n "${CS_SESSION_START_STAGE_FILE:-}" ] || return 0
  printf '%s\n' "$1" > "$CS_SESSION_START_STAGE_FILE" 2>/dev/null || true
}

# shellcheck source=bin/cs-timeout-lib.sh
. "$SCRIPT_DIR/cs-timeout-lib.sh"

if [ -z "${CS_SESSION_START_STAGE_FILE:-}" ]; then
  SESSION_START_BUDGET=${CS_SESSION_START_TIMEOUT:-120}
  # A non-positive or non-numeric budget is not a budget (`timeout 0` disables
  # the deadline outright), so an unusable value falls back to the default
  # rather than silently removing the bound.
  case "$SESSION_START_BUDGET" in ''|*[!0-9]*|0) SESSION_START_BUDGET=120 ;; esac
  SESSION_START_STAGE_FILE=$(mktemp "${TMPDIR:-/tmp}/cs-session-start-stage.XXXXXX" 2>/dev/null) || SESSION_START_STAGE_FILE=
  if [ -z "$SESSION_START_STAGE_FILE" ]; then
    # Without a breadcrumb the bound still holds; only the banner's precision
    # is lost, so the child still runs bounded.
    SESSION_START_STAGE_FILE=/dev/null
  fi
  cs_run_timed "$SESSION_START_BUDGET" \
    env CS_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
    "$SCRIPT_DIR/cs-session-start.sh" "$@"
  SESSION_START_RC=$?
  BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  if [ "$SESSION_START_RC" -eq "$CS_TIMEOUT_UNAVAILABLE" ]; then
    # The bound could not be established, so the digest never started. Saying
    # "it stalled" here would name a stage that never ran; the honest report is
    # that nothing above came from this session at all.
    printf '\n%s\n' "$BAR"
    printf '●  STARTUP DID NOT RUN - THE RUNTIME BOUND COULD NOT BE ESTABLISHED\n'
    printf '●  The bounded runner could not create its temporary state (check TMPDIR),\n'
    printf '●  so the digest was never started and NONE of these stages ran:\n'
    printf '●    %s\n' "$SESSION_START_STAGES"
    printf '●  The READ-ONCE CONTRACT covers nothing from this session: no source was\n'
    printf '●  printed, so nothing here has been reconciled.\n'
    printf '●  Fix the temp directory and rerun bin/cs-session-start.sh before acting on\n'
    printf '●  fleet state - a home this session never read is a home it cannot steer.\n'
    printf '%s\n' "$BAR"
  elif [ "$SESSION_START_RC" -eq 124 ]; then
    SESSION_START_LAST_STAGE=$(cat "$SESSION_START_STAGE_FILE" 2>/dev/null) || SESSION_START_LAST_STAGE=
    [ -n "$SESSION_START_LAST_STAGE" ] || SESSION_START_LAST_STAGE=unknown
    SESSION_START_PENDING=$(
      printf '%s\n' "$SESSION_START_STAGES" | tr ' ' '\n' |
        awk -v from="$SESSION_START_LAST_STAGE" '$0 == from {seen = 1; next} seen' | tr '\n' ' '
    )
    [ -n "${SESSION_START_PENDING% }" ] || SESSION_START_PENDING='(unknown - the digest may be incomplete anywhere)'
    printf '\n%s\n' "$BAR"
    printf '●  STARTUP TRUNCATED - SESSION START HIT ITS %ss RUNTIME BOUND\n' "$SESSION_START_BUDGET"
    printf '●  It STALLED during the "%s" stage, so everything above is complete only\n' "$SESSION_START_LAST_STAGE"
    printf '●  up to that point, and these stages NEVER RAN:\n'
    printf '●    %s\n' "${SESSION_START_PENDING% }"
    printf '●  The READ-ONCE CONTRACT does not cover the stalled stage or the stages that\n'
    printf '●  never ran: their sources were never printed and must be reconciled before\n'
    printf '●  acting on anything they would have shown.\n'
    printf '●  Rerun bin/cs-session-start.sh now to finish startup. If it truncates again,\n'
    printf '●  raise CS_SESSION_START_TIMEOUT and report the slow stage - a stage that\n'
    printf '●  cannot finish inside the bound is a fleet problem, not a reporting detail.\n'
    printf '%s\n' "$BAR"
  fi
  [ "$SESSION_START_STAGE_FILE" = /dev/null ] || rm -f "$SESSION_START_STAGE_FILE" 2>/dev/null || true
  # The digest normalizes to exit 0 so an ordinary problem report never reads
  # as a hook failure. Exit 78 is the one deliberate exception, reserved for
  # the fatal BASH_FLOOR refusal (see the bootstrap stage below): a pre-floor
  # interpreter makes the nameref argv builders silently return empty arrays,
  # so that refusal must stay visible to whatever ran this script.
  if [ "$SESSION_START_RC" -eq 78 ]; then
    exit 78
  fi
  exit 0
fi

# Session start is one of the two legitimate layout-gate bypasses: it must be
# able to acquire the lock and run the migrator against a not-yet-migrated
# home. The bypass is NOT exported: every child except cs-lock.sh and the
# migrator still fails closed until the migration below has converged.
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
CS_LAYOUT_GATE_SKIP=1
cs_resolve_root
CS_LAYOUT_GATE_SKIP=

# shellcheck source=bin/cs-herdr-lib.sh
. "$SCRIPT_DIR/cs-herdr-lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$SCRIPT_DIR/cs-meta-lib.sh"
# shellcheck source=bin/cs-operational-input.sh
. "$SCRIPT_DIR/cs-operational-input.sh"
# shellcheck source=bin/cs-line-cap-lib.sh
. "$SCRIPT_DIR/cs-line-cap-lib.sh"

STATUS_TAIL=${CS_SESSION_START_STATUS_TAIL:-5}
case "$STATUS_TAIL" in ''|*[!0-9]*) STATUS_TAIL=5 ;; esac
QUEUED_LIMIT=${CS_SESSION_START_QUEUED_LIMIT:-20}
case "$QUEUED_LIMIT" in ''|*[!0-9]*|0) QUEUED_LIMIT=20 ;; esac
ACTIVE_LIMIT=${CS_SESSION_START_ACTIVE_LIMIT:-40}
case "$ACTIVE_LIMIT" in ''|*[!0-9]*|0) ACTIVE_LIMIT=40 ;; esac
BACKLOG_FIELDS=blocked_by,hold_kind,hold_reason
FOLLOWUP_FIELDS=delivery_state,$BACKLOG_FIELDS

RULE='================================================================================'
SUBRULE='--------------------------------------------------------------------------------'

section() { printf '\n%s\n%s\n%s\n' "$RULE" "$1" "$RULE"; }
subsection() { printf '\n%s\n%s\n' "$1" "$SUBRULE"; }

print_file_or_absent() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      cat "$path"
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

# Startup memory - config/boss.md, config/boss-shared.md, config/learnings.md - is
# read IN FULL at every session start of every home, so its cost is paid by
# every session whether or not that session ever uses it. Unlike the registries
# printed alongside it, whose size is bounded by how many projects and capos
# exist, curated prose has no natural ceiling: each sweep adds and nothing
# forces a prune, so it grows monotonically and the digest quietly gets more
# expensive forever.
#
# The budget makes that visible at the one place every session already reads,
# and names its owner. It is a REPORT, never a truncation: this script will not
# decide which of the boss's own preferences to drop. /vault owns consolidation.
STARTUP_MEMORY_MAX_BYTES=${CS_STARTUP_MEMORY_MAX_BYTES:-8192}
case "$STARTUP_MEMORY_MAX_BYTES" in ''|*[!0-9]*|0) STARTUP_MEMORY_MAX_BYTES=8192 ;; esac

print_startup_memory() {  # <path> <label> - print, then report if over budget
  local path=$1 label=$2 size
  print_file_or_absent "$path" "$label"
  [ -f "$path" ] || return 0
  size=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -gt "$STARTUP_MEMORY_MAX_BYTES" ] || return 0
  printf '\nOVER STARTUP-MEMORY BUDGET: %s bytes against a %s-byte budget.\n' \
    "$size" "$STARTUP_MEMORY_MAX_BYTES"
  printf 'Every session of this home pays this cost on every start.\n'
  printf 'Load /vault and consolidate this file back under budget (owner: skills/vault).\n'
}

backlog_backend() {
  local b
  b=$(cat "$CONFIG/backlog-backend.conf" 2>/dev/null || true)
  case "$b" in
    manual) printf 'manual' ;;
    *) printf 'tasks-axi' ;;
  esac
}

# The two markers a queued title line carries in its own text, kept apart
# because they earn different treatment: a held or blocked row joins the bounded
# actionable group, while a public-followup row is an obligation no bound may
# hide. The manual renderer has no task model, so the title line is the only
# signal it gets, and these are the markers tasks-axi's markdown backend writes:
# "(hold: ...)", "(hold-kind: ...)", "blocked-by: ...", and
# "(kind: public-followup)". Bracket expressions rather than backslashes,
# because awk's -v applies escape processing before the regex is ever compiled.
MANUAL_HELD_RE='[(]hold|blocked-by:'
MANUAL_FOLLOWUP_RE='[(]kind:[[:space:]]*public-followup[)]'

print_backlog_manual_compact() {
  local path=$1 reason=$2
  printf 'compact backlog listing (%s; done rows omitted; in-flight, held, and blocked title lines bounded to %s per group; public-followup rows never bounded; other queued bounded to %s; indented task bodies omitted)\n' \
    "$reason" "$ACTIVE_LIMIT" "$QUEUED_LIMIT"
  awk -v max="$QUEUED_LIMIT" -v active_max="$ACTIVE_LIMIT" \
    -v held_re="$MANUAL_HELD_RE" -v followup_re="$MANUAL_FOLLOWUP_RE" '
    function state_for_heading(line, heading) {
      heading = line
      sub(/^##[[:space:]]+/, "", heading)
      sub(/[[:space:]]+$/, "", heading)
      if (heading == "In flight") return "in_flight"
      if (heading == "Queued") return "queued"
      if (heading == "Done") return "done"
      return ""
    }
    /^##[[:space:]]+/ {
      state = state_for_heading($0)
      # The Done heading is recognized so its items are skipped, never printed.
      if (state != "" && state != "done") print $0
      next
    }
    state == "in_flight" && /^[-*][[:space:]]+/ {
      in_flight++
      if (in_flight_shown < active_max) { in_flight_shown++; print $0 }
      next
    }
    state == "done" && /^[-*][[:space:]]+/ { done_total++; next }
    state == "queued" && /^[-*][[:space:]]+/ {
      queued_total++
      # A delivery obligation first, whatever else its title line also says: no
      # bound below may cost the boss one.
      if ($0 ~ followup_re) { followup++; print $0; next }
      if ($0 ~ held_re) {
        held++
        if (held_shown < active_max) { held_shown++; print $0 }
        next
      }
      if (plain_shown < max) { plain_shown++; print $0 }
      next
    }
    END {
      plain_total = queued_total - held - followup
      if (in_flight + queued_total + done_total == 0) {
        print "(no backlog item title lines found)"
      } else {
        printf "(shown %d of %d in-flight, %d of %d held or blocked queued, all %d public-followup queued, %d of %d other queued title line(s); %d done row(s) omitted)\n", \
          in_flight_shown, in_flight, held_shown, held, followup, plain_shown, plain_total, done_total
        if (in_flight > in_flight_shown) {
          printf "(%d more in-flight - raise CS_SESSION_START_ACTIVE_LIMIT, or read the In flight section of config/backlog.md for those rows)\n", in_flight - in_flight_shown
        }
        if (held > held_shown) {
          printf "(%d more held or blocked queued - raise CS_SESSION_START_ACTIVE_LIMIT, or read the Queued section of config/backlog.md for those rows)\n", held - held_shown
        }
        if (plain_total > plain_shown) {
          printf "(%d more queued - raise CS_SESSION_START_QUEUED_LIMIT, or read the Queued section of config/backlog.md for those rows)\n", plain_total - plain_shown
        }
      }
    }
  ' "$path"
}

# Bound one composed group without rewriting the tool's own rendering: a
# tasks-axi listing is a TOON header line followed by its indented rows, so the
# rows under that header are the only lines this touches and every other line
# passes through untouched (`tasks-axi ready` prints its public-followup group
# under a header of its own, which therefore stays whole). Whatever is cut is
# disclosed with an exact remainder count and the command that prints the rest.
#
# tasks-axi also closes every listing with its own help block. This section
# composes five listings, so keeping them would repeat the same pointers five
# times, once per group; the section prints one equivalent pointer of its own
# instead, so each group stops at its `help[` header.
print_axi_group_bounded() {  # <text> <header-prefix> <max> <label> <full-command>
  local text=$1 header=$2 max=$3 label=$4 command=$5
  printf '%s\n' "$text" | awk -v header="$header" -v max="$max" -v label="$label" -v command="$command" '
    /^help\[/ { exit }
    index($0, header) == 1 { rows = 1; print; next }
    rows && /^[[:space:]]/ {
      total++
      if (shown < max) { print; shown++ }
      next
    }
    { rows = 0; print }
    END {
      if (total > 0) {
        printf "(shown %d of %d %s item(s))\n", shown, total, label
        if (total > shown) {
          printf "(%d more %s - %s)\n", total - shown, label, command
        }
      }
    }
  '
}

# The obligations group takes no bound at all, so it needs no counters either:
# the tool's own count header already says how many there are, and every row
# under it prints.
print_axi_group_unbounded() {  # <text>
  printf '%s\n' "$1" | awk '/^help\[/ { exit } { print }'
}

print_backlog_tasks_axi_compact() {
  local path=$1 in_flight held blocked followups ready err
  if ! in_flight=$(tasks-axi list --file "$path" --state in_flight --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$in_flight
  elif ! held=$(tasks-axi list --file "$path" --state held --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$held
  elif ! blocked=$(tasks-axi list --file "$path" --state queued --blocked --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$blocked
  elif ! followups=$(tasks-axi list --file "$path" --state queued --kind public-followup --fields "$FOLLOWUP_FIELDS" 2>&1); then
    err=$followups
  elif ! ready=$(tasks-axi ready --file "$path" 2>&1); then
    err=$ready
  else
    printf 'compact backlog listing (tasks-axi; done rows omitted; in-flight, held, and blocked rows shown in full up to %s per group; queued public-followup obligations always shown in full; ready queued bounded to %s; task bodies omitted)\n' \
      "$ACTIVE_LIMIT" "$QUEUED_LIMIT"
    printf '\nin flight:\n'
    print_axi_group_bounded "$in_flight" 'tasks[' "$ACTIVE_LIMIT" 'in-flight' \
      "tasks-axi list --file $path --state in_flight --fields $BACKLOG_FIELDS"
    printf '\nheld (boss- or time-gated; an in-flight item that is also held appears in both groups):\n'
    print_axi_group_bounded "$held" 'tasks[' "$ACTIVE_LIMIT" 'held' \
      "tasks-axi list --file $path --state held --fields $BACKLOG_FIELDS"
    printf '\nblocked queued:\n'
    print_axi_group_bounded "$blocked" 'tasks[' "$ACTIVE_LIMIT" 'blocked queued' \
      "tasks-axi list --file $path --state queued --blocked --fields $BACKLOG_FIELDS"
    printf '\nqueued public-followup obligations (never bounded; delivery the boss is already owed):\n'
    print_axi_group_unbounded "$followups"
    printf '\nready queued (dispatchable now):\n'
    print_axi_group_bounded "$ready" 'ready[' "$QUEUED_LIMIT" 'ready queued' \
      "tasks-axi ready --file $path"
    return 0
  fi
  printf 'tasks-axi compact listing failed; falling back to title-line rendering.\n'
  printf '%s\n' "$err"
  print_backlog_manual_compact "$path" "fallback"
}

print_backlog_compact() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      if [ "$(backlog_backend)" = tasks-axi ] && command -v tasks-axi >/dev/null 2>&1; then
        print_backlog_tasks_axi_compact "$path"
      else
        print_backlog_manual_compact "$path" "$(backlog_backend) backend"
      fi
      printf 'Full task bodies remain available on demand: tasks-axi show <id> --full, or config/backlog.md.\n'
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

print_status_tail() {
  local status=$1 line
  printf 'status tail (last %s line(s), each capped at %s characters, wake-EVENT history, not current state; full log: %s):\n' \
    "$STATUS_TAIL" "$CS_LINE_CAP_DEFAULT" "$status"
  # A soldier writes its own status lines, so their length is unbounded: one
  # observed line ran roughly 200 characters. Cap each one the way the wake
  # digest's OPEN DECISIONS section does; the lede carries the state word and
  # the key, and the full log path above reaches the rest.
  while IFS= read -r line || [ -n "$line" ]; do
    cs_cap_line "$line"
  done < <(tail -n "$STATUS_TAIL" "$status")
}

# Completion proof for the session-open router: bin/cs-sessionstart-run.sh
# re-emits on clear/compact only when this file records the current lock
# owner's pid, so a startup killed mid-sweep is finished first.
COMPLETION_FILE="$STATE/.session-start-complete"

# Prefix the complete digest with its structural type. section starts with a
# newline, which becomes the first byte of the body after the canonical ": ".
cs_operational_input_construct session-start '' SESSION_START_PREFIX
printf '%s' "$SESSION_START_PREFIX"
if [ "$REEMIT" -eq 1 ]; then
  section "SESSION START (CONTEXT RE-EMIT) - $CS_HOME"
  printf 'This session already completed a full startup and has only lost its context.\n'
  printf 'Lock ownership is re-verified and the durable records below are reprinted, but\n'
  printf 'the sweeps startup already reconciled - the config/ layout migration, project\n'
  printf 'clone refresh, and capo fast-forward and liveness - are NOT repeated.\n'
  printf 'Queued wakes ARE still drained: they arrived after startup and are this turn'"'"'s work.\n'
else
  section "SESSION START - $CS_HOME"
fi

# --- 1. lock -----------------------------------------------------------
# The gate bypass covers only the lock: an unmigrated home must still be able
# to elect the one session that will migrate it.
stage lock
subsection "LOCK"
LOCK_OUT=$(CS_LAYOUT_GATE_SKIP=1 "$SCRIPT_DIR/cs-lock.sh" 2>&1)
LOCK_RC=$?
printf '%s\n' "$LOCK_OUT"
READ_ONLY=0
if [ "$LOCK_RC" -ne 0 ]; then
  READ_ONLY=1
  BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '%s\n' "$BAR"
    printf '●  READ-ONLY SESSION - ANOTHER LIVE CONSIGLIERE SESSION HOLDS THE FLEET LOCK\n'
    printf '●  %s\n' "$LOCK_OUT"
    printf '●  Skipping every mutating step: fleet sync, capo sync, and wake-queue\n'
    printf '●  drain. Detect-only bootstrap diagnostics and the rest of this\n'
    printf '●  read-only-safe digest still ran below.\n'
    printf '●  Operate read-only until this resolves - do not spawn, steer, merge, or\n'
    printf '●  otherwise mutate fleet state from this session.\n'
    printf '%s\n' "$BAR"
  }
fi
# A FULL locked startup invalidates any earlier completion proof until every
# stage below has run, so a truncated run can never be re-emitted from.
if [ "$READ_ONLY" -eq 0 ] && [ "$REEMIT" -eq 0 ]; then
  rm -f "$COMPLETION_FILE" 2>/dev/null || true
fi

# --- 1b. config/ layout migration (one-shot, idempotent, quiet no-op) ----
# Runs only in the locked session, immediately after the lock, so every later
# step - and every other script's fail-closed layout gate - sees a migrated
# home. A refusal (divergent old+new content) stops the digest: nothing else
# can run correctly until the named files are reconciled. A re-emit skips it:
# completion proof means the startup that owns this context already converged
# it.
if [ "$READ_ONLY" -eq 0 ] && [ "$REEMIT" -eq 0 ]; then
  MIGRATE_OUT=$("$SCRIPT_DIR/cs-migrate-config.sh" 2>&1)
  MIGRATE_RC=$?
  if [ -n "$MIGRATE_OUT" ]; then
    subsection "LAYOUT MIGRATION"
    printf '%s\n' "$MIGRATE_OUT"
  fi
  if [ "$MIGRATE_RC" -ne 0 ]; then
    printf 'Session start stops here: the config/ layout migration was refused above.\n'
    printf 'Reconcile the named files by hand, then start the session again.\n'
    exit 1
  fi
fi

# --- 1c. deferred network stage (started, never waited on) -----------------
# Every network call this session start owes is launched HERE, detached and
# bounded, so it runs concurrently with the whole digest below instead of in
# front of it. Step 7 harvests whatever it has finished, without ever waiting.
# --reemit passes --locked 0 for the same reason it runs bootstrap detect-only:
# this process already ran the mutating sweeps at its own startup, so only the
# read-only GitHub-auth probe is owed. A read-only session starts nothing at
# all: it holds no mutation authority for the sweeps, and it must not spawn,
# steer, or merge anyway, so it has no action left for an auth verdict to gate.
NETWORK_STAGE_STARTED=0
if [ "$READ_ONLY" -eq 0 ]; then
  NETWORK_STAGE_LOCKED=1
  [ "$REEMIT" -eq 0 ] || NETWORK_STAGE_LOCKED=0
  if "$SCRIPT_DIR/cs-startup-network.sh" start \
    --locked "$NETWORK_STAGE_LOCKED" --harvest-pid $$ >/dev/null 2>&1; then
    NETWORK_STAGE_STARTED=1
  fi
fi

# --- 2. bootstrap --------------------------------------------------------
# CS_BOOTSTRAP_NETWORK=skip on every path: bootstrap's own network half is what
# the deferred stage above is running right now, and running it here too would
# both re-block this digest and race the worker's sweeps against themselves.
stage bootstrap
subsection "BOOTSTRAP"
BOOT_RC=0
if [ "$READ_ONLY" -eq 1 ]; then
  BOOT_OUT=$(CS_BOOTSTRAP_DETECT_ONLY=1 CS_BOOTSTRAP_NETWORK=skip "$SCRIPT_DIR/cs-bootstrap.sh" 2>&1) || BOOT_RC=$?
elif [ "$REEMIT" -eq 1 ]; then
  # Detect-only because startup already ran the sweeps, LOCKED because this
  # session still owns repair - it must not defer to a lock holder that is
  # itself.
  BOOT_OUT=$(CS_BOOTSTRAP_DETECT_ONLY=1 CS_BOOTSTRAP_LOCKED=1 CS_BOOTSTRAP_NETWORK=skip \
    "$SCRIPT_DIR/cs-bootstrap.sh" 2>&1) || BOOT_RC=$?
else
  BOOT_OUT=$(CS_BOOTSTRAP_NETWORK=skip "$SCRIPT_DIR/cs-bootstrap.sh" 2>&1) || BOOT_RC=$?
fi
if [ -n "$BOOT_OUT" ]; then
  printf '%s\n' "$BOOT_OUT"
else
  printf '(silent - all good)\n'
fi
# Only bootstrap's BASH_FLOOR blocker is session-fatal: below the floor the
# nameref argv builders silently return empty arrays, so proceeding would
# launch soldiers with no autonomy flag rather than fail honestly. Every other
# bootstrap report deliberately stays a soft digest line - making them fatal
# could wedge every home in the fleet on a single soft dependency warning.
if [ "$BOOT_RC" -ne 0 ] && printf '%s\n' "$BOOT_OUT" | grep -q '^BASH_FLOOR:'; then
  printf 'SESSION START REFUSED: bootstrap reported the fatal BASH_FLOOR blocker above; fix the interpreter before dispatching anything.\n'
  exit 78
fi

# --- 3. wake-drain -------------------------------------------------------
stage wake-queue
subsection "WAKE QUEUE"
if [ "$READ_ONLY" -eq 1 ]; then
  QLEN=0
  [ -s "$STATE/.wake-queue" ] && QLEN=$(grep -c . "$STATE/.wake-queue" 2>/dev/null || printf '0')
  printf 'skipped (read-only session) - %s record(s) remain queued for the session holding the lock.\n' "$QLEN"
  GUARD_OUT=$(CS_GUARD_READ_ONLY=1 "$SCRIPT_DIR/cs-guard.sh" 2>&1)
  [ -n "$GUARD_OUT" ] && printf '%s\n' "$GUARD_OUT"
else
  DRAIN_OUT=$("$SCRIPT_DIR/cs-wake-drain.sh" 2>&1)
  if [ -n "$DRAIN_OUT" ]; then
    printf '%s\n' "$DRAIN_OUT"
  else
    printf '(no queued wakes)\n'
  fi
fi

# Refresh root's endpoint identity before message recovery can use it.
if [ "$READ_ONLY" -eq 0 ] && [ -n "${HERDR_PANE_ID:-}" ]; then
  ROOT_ENDPOINT_GENERATION="root-$(date +%s)-$RANDOM"
  ROOT_ENDPOINT_TMP="$STATE/.home-endpoint-generation.tmp.$$"
  printf '%s\n' "$ROOT_ENDPOINT_GENERATION" > "$ROOT_ENDPOINT_TMP" 2>/dev/null &&
    mv -f "$ROOT_ENDPOINT_TMP" "$STATE/.home-endpoint-generation" 2>/dev/null ||
    rm -f "$ROOT_ENDPOINT_TMP" 2>/dev/null || true
fi

# Reconcile durable parent/child messages after the queue drain and before the
# foreground supervision instructions. Recovery is one bounded pass: it may
# re-wake an exact durable record, but it never starts a retry loop.
stage message-recovery
subsection "MESSAGE RECOVERY"
if [ "$READ_ONLY" -eq 1 ]; then
  printf 'skipped (read-only session) - the session holding the lock owns message recovery.\n'
else
  RECOVERY_OUT=$(CS_HOME="$CS_HOME" CS_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/cs-recover.sh" 2>&1) || RECOVERY_RC=$?
  RECOVERY_RC=${RECOVERY_RC:-0}
  if [ -n "$RECOVERY_OUT" ]; then
    printf '%s\n' "$RECOVERY_OUT"
  else
    printf 'recover: checked=0 re-woke=0\n'
  fi
  if [ "$RECOVERY_RC" -ne 0 ]; then
    printf 'recovery: unresolved records remain; inspect the errors above before acting on them.\n'
  fi
fi

# --- 4. supervision operating instructions ----------------------------------
stage supervision
AFK_PRESENT=0
[ -e "$STATE/.afk" ] && AFK_PRESENT=1

# A session start is a fresh turn. Drop any per-turn checkpoint counter left
# behind by a turn that died before its turn-end hook could clear it, or the
# first checkpoint of this session would be refused as a repeat.
rm -f "$STATE/.checkpoint-turn" 2>/dev/null || true

subsection "SUPERVISION (foreground checkpoint)"
if [ "$READ_ONLY" -eq 1 ]; then
  cat <<'EOF'
Read-only session: do NOT arm or repair supervision from here; the session
holding the lock owns the live cycle.
EOF
elif [ "$AFK_PRESENT" -eq 1 ]; then
  cat <<'EOF'
Away mode is active. This home is supervised exactly like an attended one -
the persistent monitor keeps the watcher running and bin/cs-activate.sh starts
the next turn when a wake lands - so the ordinary drain-and-checkpoint cycle
below still applies. Load /afk for the away-mode framing (batching, escalation
digests, bossless mode).
EOF
else
  cat <<'EOF'
When this session owns supervision:
1. Drain first with bin/cs-wake-drain.sh.
2. Run at most ONE foreground watcher checkpoint per turn:
     bin/cs-watch-checkpoint.sh --seconds "${CS_WATCH_CHECKPOINT:-180}"
3. Whatever it returns - a wake (signal:, stale:, check:, heartbeat) or
   a quiet checkpoint (prints checkpoint: / exits 124) - drain queued wakes,
   handle what they report, say what happened, and END the turn. A second
   checkpoint in the same turn is refused: a turn boundary is the only moment
   the boss's message can reach you.
4. Ending the turn does not end supervision. The persistent monitor keeps
   watching this home, queued wakes are durable, and a wake that sits starts
   the next turn on its own.
5. Never use shell '&' or background tasks for watcher supervision; the harness
   cannot reason during a foreground tool call, and the bounded checkpoint is
   the only sanctioned wait shape.
6. Failure or missing cycle only: drain queued wakes, inspect the failure,
   then start a fresh foreground checkpoint.
The Stop-hook guard (bin/cs-turnend-guard.sh) blocks a turn end only when this
home could not wake itself.
EOF
fi

# Record THIS home's own agent pane, durably. bin/cs-activate.sh needs a target
# to prompt when the queue sits, and session start is the one place that runs
# inside the home's own pane, where HERDR_PANE_ID proves which pane that is.
# It is a hint, never an identity: herdr recycles pane ids, so cs-activate.sh
# revalidates (pane exists, still has an agent, still rooted in this home)
# before it will prompt anything.
if [ -n "${HERDR_PANE_ID:-}" ]; then
  printf '%s\n' "$HERDR_PANE_ID" > "$STATE/.home-pane" 2>/dev/null || true
fi

# --- 5. read-once contract -------------------------------------------------
# Ahead of the two digests it governs, not after them: a truncated tail is
# exactly what drops a closing reminder, and this contract is what stops the
# next turn from re-reading everything the digest just printed. Because it
# arrives BEFORE its subject, it also names the one condition that voids it -
# a stage this digest reports as never emitted. That condition is a real
# signal, not prose: the runtime bound's STARTUP TRUNCATED banner (see this
# file's RUNTIME BOUND note) is what reports a stalled stage and the stages
# that never ran.
stage read-once
section "READ-ONCE CONTRACT"
cat <<'EOF'
Everything below is printed in full for this session start: every state/*.meta,
a compact config/backlog.md listing, a bounded tail of every state/*.status,
the standing board sweeps, config/projects.md, config/boards.md, host/capos.md,
config/boss.md, config/boss-shared.md, and config/learnings.md.
Do NOT re-read any of them after reading this digest, and do NOT bulk-read
config/backlog.md or state/*.status: re-reading everything defeats the entire
point of this command.

Go to a source directly only when:
  - this digest flagged it ABSENT (then rebuild or create it per AGENTS.md),
  - its contents looked unparseable or corrupt,
  - an individual full status log is needed for older wake-event history, or a
    status line was capped and its tail matters (each task's full log path is
    printed with its tail),
  - a full task body is needed (tasks-axi show <id> --full, or config/backlog.md),
  - the backlog listing disclosed omitted rows in any of its groups - in-flight,
    held or blocked, or queued - and this turn needs them, in which case take the
    targeted follow-up that disclosure names (the group's own tasks-axi listing,
    or that one section of config/backlog.md) rather than a bulk read,
  - the NETWORK CHECKS section reported its checks still IN PROGRESS and this
    turn needs their verdict (bin/cs-startup-network.sh read),
  - or this digest reports a stage as never emitted (a truncated startup names
    the stages that never ran), in which case that stage's sources were never
    printed and must be reconciled.
EOF

# --- 6. fleet-state digest ---------------------------------------------
# Before CONTEXT: see this file's ORDERING note. Live fleet identity is what a
# truncated tail must never take.
stage fleet-state
section "FLEET STATE"

# The live-task inventory opens the section, ahead of the backlog listing and
# the sweeps: which tasks exist, where they run, and whether their endpoints are
# alive is the record recovery depends on, and every bound below it is a bound
# on something the fleet can grow without limit. Nothing that scales with fleet
# size may sit between the top of the digest's payload and this block.
subsection "Work under way (state/*.meta)"
META_FOUND=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  META_FOUND=1
  id=$(basename "$meta" .meta)
  printf '\n--- %s ---\n' "$id"
  cat "$meta"

  pane=$(cs_meta_get "$meta" pane 2>/dev/null || true)
  if [ -n "$pane" ]; then
    if cs_herdr_pane_exists "$pane"; then
      if cs_herdr_agent_alive "$pane"; then
        printf 'endpoint: alive (pane=%s, agent detected)\n' "$pane"
      else
        printf 'endpoint: pane present, no agent detected (pane=%s)\n' "$pane"
      fi
    else
      printf 'endpoint: dead (pane=%s)\n' "$pane"
    fi
  else
    printf 'endpoint: unknown (no pane recorded)\n'
  fi

  status="$STATE/$id.status"
  if [ -f "$status" ]; then
    print_status_tail "$status"
  else
    printf 'status tail: (no status file yet: %s)\n' "$status"
  fi
done
[ "$META_FOUND" -eq 1 ] || printf '(none)\n'

subsection "Orphan status logs (state/*.status without matching .meta)"
ORPHAN_STATUS_FOUND=0
for status in "$STATE"/*.status; do
  [ -f "$status" ] || continue
  id=$(basename "$status" .status)
  [ -f "$STATE/$id.meta" ] && continue
  ORPHAN_STATUS_FOUND=1
  printf '\n--- %s ---\n' "$id"
  print_status_tail "$status"
done
[ "$ORPHAN_STATUS_FOUND" -eq 1 ] || printf '(none)\n'

print_backlog_compact "$CONFIG/backlog.md" "config/backlog.md"

subsection "Board sweeps (data/sweeps.md)"
if [ "$READ_ONLY" -eq 1 ]; then
  printf 'read-only session: reporting sweeps without converging their polls.\n'
else
  SWEEP_SYNC=$("$SCRIPT_DIR/cs-board-watch.sh" sync 2>&1) || true
  [ -n "$SWEEP_SYNC" ] && printf '%s\n' "$SWEEP_SYNC"
fi
"$SCRIPT_DIR/cs-board-watch.sh" list 2>&1 || true

subsection "AFK"
if [ -e "$STATE/.afk" ]; then
  printf 'present - away-mode supervision is active; the watch/monitor/activate triangle covers this home exactly like an attended one.\n'
else
  printf 'absent\n'
fi

# --- 7. network checks ------------------------------------------------------
# Deliberately here and not later: these lines are actionable (broken GitHub
# auth, a stuck clone), and the section after this one is the curated memory a
# truncated tail is meant to take first.
# Deliberately here and not earlier: this is the last point in the digest, so
# the worker started at step 1 has had the whole composition above to finish in.
# It is a NON-BLOCKING read either way - whatever the worker has published by
# now is printed, and whatever it has not is named as not yet confirmed.
stage network-checks
section "NETWORK CHECKS"
if [ "$READ_ONLY" -eq 1 ]; then
  printf 'skipped (read-only session) - GitHub authentication and project clone refresh\n'
  printf 'were not run. They need the fleet lock, and this session must not spawn, steer,\n'
  printf 'or merge, so it has no action they would gate. The session holding the lock runs\n'
  printf 'them.\n'
elif [ "$NETWORK_STAGE_STARTED" -eq 0 ]; then
  printf 'NETWORK_CHECKS: the deferred check stage could not be started, so GitHub\n'
  printf 'authentication and project clone refresh did not run; start them with\n'
  printf '%s/bin/cs-startup-network.sh run --locked 1\n' "$CS_ROOT"
else
  "$SCRIPT_DIR/cs-startup-network.sh" harvest --pid $$ 2>&1 || true
fi

# --- 8. context digest -----------------------------------------------------
# Last of the bulk sections deliberately: curated memory is stable session to
# session, already reported against CS_STARTUP_MEMORY_MAX_BYTES, and
# recoverable with one targeted read, so it is the cheapest thing for a
# truncated tail to take (see this file's ORDERING note).
stage context
section "CONTEXT"
print_file_or_absent "$CONFIG/projects.md" "config/projects.md"
print_file_or_absent "$CONFIG/boards.md" "config/boards.md (GitHub board mapping for the contracts and casino skills)"
print_file_or_absent "$HOST_DIR/capos.md" "host/capos.md (host-local; ABSENT = no capos provisioned here)"
print_startup_memory "$CONFIG/boss.md" "config/boss.md"
print_startup_memory "$CONFIG/boss-shared.md" "config/boss-shared.md (shared, main-authoritative, read-only in capo homes)"
print_startup_memory "$CONFIG/learnings.md" "config/learnings.md"

# --- 9. closing reminder -----------------------------------------------
stage next-step
section "NEXT STEP"
if [ "$READ_ONLY" -eq 1 ]; then
  cat <<'EOF'
This session did not acquire the fleet lock. Stay read-only: do not arm,
drain, spawn, steer, merge, or repair fleet state from here. The session
holding the lock owns mutable follow-up.

EOF
elif [ "$AFK_PRESENT" -eq 1 ]; then
  cat <<'EOF'
Away mode is active. Follow the supervision operating block above (foreground
checkpoint) exactly as an attended home would; load /afk for the away-mode
framing on top of it.

EOF
else
  cat <<'EOF'
Follow the supervision operating block above (foreground checkpoint).
This script never starts supervision itself.

EOF
fi
cat <<'EOF'
The digest above is complete for this session start. The READ-ONCE CONTRACT
section near the top of it governs what may still be read from disk.
EOF

# Record completion proof for the session-open router, atomically and only for
# a full locked startup that reached this point: the recorded pid must match
# the lock owner or a later clear/compact runs a full startup instead.
if [ "$READ_ONLY" -eq 0 ] && [ "$REEMIT" -eq 0 ]; then
  COMPLETION_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$COMPLETION_PID" in
    ''|*[!0-9]*) COMPLETION_PID= ;;
  esac
  COMPLETION_TMP=$(mktemp "$STATE/.session-start-complete.XXXXXX" 2>/dev/null || true)
  if [ -n "$COMPLETION_PID" ] && [ -n "$COMPLETION_TMP" ] \
    && printf '%s\n' "$COMPLETION_PID" > "$COMPLETION_TMP" 2>/dev/null \
    && mv -f "$COMPLETION_TMP" "$COMPLETION_FILE" 2>/dev/null; then
    :
  else
    [ -z "$COMPLETION_TMP" ] || rm -f "$COMPLETION_TMP" 2>/dev/null || true
    printf '\nSESSION_START_COMPLETION: not recorded - the next clear or compact will run a full startup.\n'
  fi
fi

exit 0
