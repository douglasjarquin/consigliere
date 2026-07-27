#!/usr/bin/env bash
# cs-session-start.sh - one command for the whole session start.
#
# Produces ONE ordered digest so a session starts in one or two turns:
#   1. lock          - acquire the per-home session lock FIRST, before any
#                      mutating step runs (cs-lock.sh).
#   2. bootstrap     - detect-only diagnostics always run; the mutating sweeps
#                      (fleet sync, capo fast-forward, capo liveness) run only
#                      when this session actually holds the lock
#                      (CS_BOOTSTRAP_DETECT_ONLY=1 otherwise).
#   3. wake-drain    - mutates the durable wake queue, so it also only runs
#                      when locked; drained records are this turn's first work
#                      queue. The read-only path leaves the queue untouched
#                      and runs cs-guard.sh in advisory mode instead.
#   4. supervision   - the ONE foreground-checkpoint operating block, inlined
#                      here (the protocol is identical across harnesses and
#                      one wait shape; there is no protocol renderer).
#   5. context       - data/projects.md, data/capos.md, data/boss.md,
#                      data/boss-shared.md, data/learnings.md, each with an
#                      explicit ABSENT marker when missing (absence is
#                      meaningful and never confused with empty-but-present).
#   6. fleet state   - compact backlog listing, every state/*.meta with a
#                      cheap endpoint liveness read, bounded status tails
#                      (wake-EVENT history, not current state), orphan status
#                      logs, and the afk flag.
#   7. next step     - points back at the supervision block; this script never
#                      starts supervision itself.
#
# COMPOSITION, NOT DUPLICATION: this script calls cs-lock.sh, cs-bootstrap.sh,
# and cs-wake-drain.sh as real subprocesses and prints their real output; all
# sequencing/formatting logic added here stays local to this file.
#
# Usage: cs-session-start.sh
#   Prints the full ordered digest to stdout and always exits 0: this is a
#   reporting command, not a gate. A lock refusal is reported as a loud banner
#   inline, never a silent failure that would make an agent skip the digest.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root

# shellcheck source=bin/cs-herdr-lib.sh
. "$SCRIPT_DIR/cs-herdr-lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$SCRIPT_DIR/cs-meta-lib.sh"
# shellcheck source=bin/cs-operational-input.sh
. "$SCRIPT_DIR/cs-operational-input.sh"

STATUS_TAIL=${CS_SESSION_START_STATUS_TAIL:-5}
case "$STATUS_TAIL" in ''|*[!0-9]*) STATUS_TAIL=5 ;; esac
BACKLOG_LIMIT=${CS_SESSION_START_BACKLOG_LIMIT:-80}
case "$BACKLOG_LIMIT" in ''|*[!0-9]*|0) BACKLOG_LIMIT=80 ;; esac

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

backlog_backend() {
  local b
  b=$(cat "$CONFIG/backlog-backend" 2>/dev/null || true)
  case "$b" in
    manual) printf 'manual' ;;
    *) printf 'tasks-axi' ;;
  esac
}

print_backlog_manual_compact() {
  local path=$1 reason=$2
  printf 'compact backlog listing (%s; max %s item(s); indented task bodies omitted)\n' "$reason" "$BACKLOG_LIMIT"
  awk -v max="$BACKLOG_LIMIT" '
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
      if (state != "") print $0
      next
    }
    state != "" && /^[-*][[:space:]]+/ {
      total++
      if (shown < max) {
        print $0
        shown++
      }
      next
    }
    END {
      if (total == 0) {
        print "(no backlog item title lines found)"
      } else {
        printf "(shown %d of %d backlog item title line(s))\n", shown, total
        if (total > shown) {
          printf "(truncated %d item(s); increase CS_SESSION_START_BACKLOG_LIMIT for a larger startup listing)\n", total - shown
        }
      }
    }
  ' "$path"
}

print_backlog_compact() {
  local path=$1 label=$2 out rc
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      if [ "$(backlog_backend)" = tasks-axi ] && command -v tasks-axi >/dev/null 2>&1; then
        printf 'compact backlog listing (tasks-axi; max %s item(s); task bodies omitted)\n' "$BACKLOG_LIMIT"
        out=$(tasks-axi list --file "$path" --limit "$BACKLOG_LIMIT" --fields blocked_by,hold_kind,hold_reason 2>&1)
        rc=$?
        if [ "$rc" -eq 0 ]; then
          printf '%s\n' "$out"
        else
          printf 'tasks-axi compact listing failed; falling back to title-line rendering.\n'
          printf '%s\n' "$out"
          print_backlog_manual_compact "$path" "fallback"
        fi
      else
        print_backlog_manual_compact "$path" "$(backlog_backend) backend"
      fi
      printf 'Full task bodies remain available on demand: tasks-axi show <id> --full, or data/backlog.md.\n'
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

print_status_tail() {
  local status=$1
  printf 'status tail (last %s line(s), wake-EVENT history, not current state; full log: %s):\n' "$STATUS_TAIL" "$status"
  tail -n "$STATUS_TAIL" "$status"
}

# Prefix the complete digest with its structural type. section starts with a
# newline, which becomes the first byte of the body after the canonical ": ".
cs_operational_input_construct session-start '' SESSION_START_PREFIX
printf '%s' "$SESSION_START_PREFIX"
section "SESSION START - $CS_HOME"

# --- 1. lock -----------------------------------------------------------
subsection "LOCK"
LOCK_OUT=$("$SCRIPT_DIR/cs-lock.sh" 2>&1)
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

# --- 2. bootstrap --------------------------------------------------------
subsection "BOOTSTRAP"
if [ "$READ_ONLY" -eq 1 ]; then
  BOOT_OUT=$(CS_BOOTSTRAP_DETECT_ONLY=1 "$SCRIPT_DIR/cs-bootstrap.sh" 2>&1)
else
  BOOT_OUT=$("$SCRIPT_DIR/cs-bootstrap.sh" 2>&1)
fi
if [ -n "$BOOT_OUT" ]; then
  printf '%s\n' "$BOOT_OUT"
else
  printf '(silent - all good)\n'
fi

# --- 3. wake-drain -------------------------------------------------------
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

# --- 4. supervision operating instructions ----------------------------------
AFK_PRESENT=0
[ -e "$STATE/.afk" ] && AFK_PRESENT=1

subsection "SUPERVISION (foreground checkpoint)"
if [ "$READ_ONLY" -eq 1 ]; then
  cat <<'EOF'
Read-only session: do NOT arm or repair supervision from here; the session
holding the lock owns the live cycle.
EOF
elif [ "$AFK_PRESENT" -eq 1 ]; then
  cat <<'EOF'
Away mode is active: the daemon owns supervision. Load /afk and ensure the
daemon is running; do not start a foreground checkpoint alongside it.
EOF
else
  cat <<'EOF'
When this session owns supervision:
1. Drain first with bin/cs-wake-drain.sh.
2. Run one foreground watcher checkpoint:
     bin/cs-watch-checkpoint.sh --seconds "${CS_WATCH_CHECKPOINT:-180}"
3. Ordinary wake: if it prints signal:, stale:, check:, or heartbeat, drain
   queued wakes, handle that wake, then start the next checkpoint in the SAME
   turn.
4. Quiet checkpoint (prints checkpoint: / exits 124): drain queued wakes
   anyway, process any queued boss message now visible, then start the next
   checkpoint.
5. Never use shell '&' or background tasks for watcher supervision; the harness
   cannot reason during a foreground tool call, and the bounded checkpoint is
   the only sanctioned wait shape.
6. Failure or missing cycle only: drain queued wakes, inspect the failure,
   then start a fresh foreground checkpoint.
No turn ends blind while work is under way; the Stop-hook guard
(bin/cs-turnend-guard.sh) is the structural backstop, not a substitute.
EOF
fi

# --- 5. context digest -----------------------------------------------------
section "CONTEXT"
print_file_or_absent "$DATA/projects.md" "data/projects.md"
print_file_or_absent "$DATA/boards.md" "data/boards.md (GitHub board mapping for the contracts and casino skills)"
print_file_or_absent "$DATA/capos.md" "data/capos.md"
print_file_or_absent "$DATA/boss.md" "data/boss.md"
print_file_or_absent "$DATA/boss-shared.md" "data/boss-shared.md (shared, main-authoritative, read-only in capo homes)"
print_file_or_absent "$DATA/learnings.md" "data/learnings.md"

# --- 6. fleet-state digest ---------------------------------------------
section "FLEET STATE"
print_backlog_compact "$DATA/backlog.md" "data/backlog.md"

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

subsection "AFK"
if [ -e "$STATE/.afk" ]; then
  printf 'present - away-mode supervision is active; the daemon owns the watcher.\n'
else
  printf 'absent\n'
fi

# --- 7. closing reminder -----------------------------------------------
section "NEXT STEP"
if [ "$READ_ONLY" -eq 1 ]; then
  cat <<'EOF'
This session did not acquire the fleet lock. Stay read-only: do not arm,
drain, spawn, steer, merge, or repair fleet state from here. The session
holding the lock owns mutable follow-up.

EOF
elif [ "$AFK_PRESENT" -eq 1 ]; then
  cat <<'EOF'
Away mode is active. Follow the supervision block above: load /afk and ensure
the daemon is running, because the daemon owns watcher supervision.

EOF
else
  cat <<'EOF'
Follow the supervision operating block above (foreground checkpoint).
This script never starts supervision itself.

EOF
fi
cat <<'EOF'
The digest above is complete for this session start. Do NOT re-read
data/projects.md, data/boards.md, data/capos.md, data/boss.md, data/boss-shared.md,
data/learnings.md, or state/*.meta now - they were just printed in full.
Do NOT bulk-read data/backlog.md now either: the compact listing was just
printed with a pointer for targeted full-body follow-up.
Do NOT bulk-read state/*.status now either: their bounded tails were just
printed with full log paths for targeted follow-up when older wake-event
history is actually needed. Re-reading everything defeats the entire point
of this command. Re-read a file only if this digest flagged it ABSENT, its
contents looked unparseable/corrupt, or an individual full status log is
needed for older wake-event history.
EOF

exit 0
