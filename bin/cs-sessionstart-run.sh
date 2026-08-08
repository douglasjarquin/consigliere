#!/usr/bin/env bash
# cs-sessionstart-run.sh - session-open entry point for the harness hooks that
# RUN the session-start digest instead of trusting the agent to. It is the one
# command .claude/settings.json and .codex/hooks.json invoke at session open,
# and it is the single owner of what a session-open source MEANS: whether this
# open needs the full digest, a context re-emit, or only a nudge.
#
# Why running beats instructing: AGENTS.md section 3 can only ASK the agent to
# run bin/cs-session-start.sh, and an agent can defer that (upstream observed a
# session that followed a recap path and never started up until a later request
# forced it). When the harness injects hook stdout into model context, running
# the digest here removes that discretion - the digest is in context before the
# model's first turn, whatever that first turn is.
#
# Usage: cs-sessionstart-run.sh [--source <source>]
#   --source  The harness's own session-open source. When omitted, the source
#             is read from a Claude/Codex-shaped JSON hook payload on stdin
#             (the `source` field). An unreadable or unrecognized source is
#             treated as `startup`, because running the digest redundantly is
#             cheap and idempotent while skipping it is the whole bug.
#
# Source routing (per-harness vocabulary: docs/claude.md, docs/codex.md):
#   startup                 full digest - this session has not started up
#   clear, compact          `--reemit` only when this lock owner recorded a
#                           completed full startup; otherwise a full digest,
#                           so a startup killed mid-sweep is finished first
#   resume, reload, fork    nudge only. Prior context is restored on these, so
#                           re-running is redundant when this session still
#                           holds the lock (silence), and one typed
#                           session-start instruction is enough when a new
#                           process resumed an old session.
#
# Every path exits 0: a Claude SessionStart hook that fails blocks session
# initialization, so a failed session start must reach the agent as digest
# text it can act on, never as a refusal to open the session. A lock another
# live session holds, broken GitHub auth, and a truncated digest are all
# reported inside the digest for exactly that reason.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A no-mistakes gate agent must never start a fleet session for the home it is
# validating; the primary-scope check below already excludes its linked gate
# worktree, and the env marker is the cheap fail-closed first line.
[ -z "${NO_MISTAKES_GATE:-}" ] || exit 0

# Session start owns layout migration, so the router must not die on the
# unmigrated-home gate; resolution failure itself stays silent (exit 0).
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
CS_LAYOUT_GATE_SKIP=1
cs_resolve_root || exit 0
CS_LAYOUT_GATE_SKIP=

# shellcheck source=bin/cs-primary-scope-lib.sh
. "$SCRIPT_DIR/cs-primary-scope-lib.sh"
cs_primary_scope_matches "$CS_ROOT" "$STATE" || exit 0

COMPLETION_FILE="$STATE/.session-start-complete"

SOURCE=
while [ $# -gt 0 ]; do
  case "$1" in
    --source)
      SOURCE=${2:-}
      # A bare trailing --source leaves the source empty rather than aborting,
      # so a malformed call still falls through to the full digest.
      if [ $# -ge 2 ]; then shift 2; else shift; fi
      ;;
    --source=*) SOURCE=${1#--source=}; shift ;;
    *) shift ;;
  esac
done

if [ -z "$SOURCE" ] && [ ! -t 0 ]; then
  # Claude and Codex both deliver a JSON SessionStart payload on stdin whose
  # `source` field carries the open reason. Parsed without jq so a host missing
  # it still gets correct routing rather than silent full runs. A terminal
  # stdin is skipped outright: a hook always pipes its payload, and an operator
  # running this by hand must not be left waiting on a read. Splitting on the
  # quote character finds the FIRST "source" key and its value without
  # depending on greedy-regex luck, and it cannot mistake a string VALUE of
  # "source" for the key, because only a key is followed by a bare colon.
  PAYLOAD=$(cat 2>/dev/null || true)
  SOURCE=$(printf '%s' "$PAYLOAD" | awk '
    BEGIN { RS = "\"" }
    seen == 2 { print; exit }
    seen == 1 && $0 ~ /^[[:space:]]*:[[:space:]]*$/ { seen = 2; next }
    seen == 1 { seen = 0 }
    $0 == "source" { seen = 1 }
  ')
fi

# True when state/.lock names a live pid in this process's own ancestry: the
# lock holder is the harness process this hook runs under, so this session
# already started up. Deliberately independent of cs-lock.sh's harness-name
# matching - ancestry is the property that matters here.
lock_is_in_ancestry() {
  local lock_pid pid=$$ _
  [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] || return 1
  IFS= read -r lock_pid < "$STATE/.lock" 2>/dev/null || return 1
  case "$lock_pid" in
    ''|*[!0-9]*|1) return 1 ;;
  esac
  kill -0 "$lock_pid" 2>/dev/null || return 1
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    [ "$pid" = "$lock_pid" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

# True only when THIS session's own completed full startup is on record: the
# lock is ours (ancestry) and the completion proof names the same pid. A
# truncated startup leaves no proof, so clear/compact after one runs the full
# digest again instead of re-emitting from a half-reconciled home.
session_start_completed() {
  local lock_pid completion_pid
  lock_is_in_ancestry || return 1
  [ -f "$COMPLETION_FILE" ] && [ ! -L "$COMPLETION_FILE" ] || return 1
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  completion_pid=$(cat "$COMPLETION_FILE" 2>/dev/null) || return 1
  case "$lock_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$completion_pid" = "$lock_pid" ]
}

case "$SOURCE" in
  resume|reload|fork)
    # Context was restored, so a run would be redundant; when this session
    # still holds the lock even the instruction is redundant, so stay silent.
    lock_is_in_ancestry && exit 0
    # shellcheck source=bin/cs-operational-input.sh
    . "$SCRIPT_DIR/cs-operational-input.sh"
    NUDGE=
    # shellcheck disable=SC2016 # the backticks are literal Markdown for the reading agent
    cs_operational_input_construct session-start \
      'Run `bin/cs-session-start.sh` now, exactly once, before executing any other instructions.' \
      NUDGE || exit 0
    printf '%s\n' "$NUDGE"
    ;;
  clear|compact)
    if session_start_completed; then
      "$SCRIPT_DIR/cs-session-start.sh" --reemit || true
    else
      "$SCRIPT_DIR/cs-session-start.sh" || true
    fi
    ;;
  *)
    "$SCRIPT_DIR/cs-session-start.sh" || true
    ;;
esac
exit 0
