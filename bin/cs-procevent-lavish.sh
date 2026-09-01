#!/usr/bin/env bash
# Lavish adapter for the process-event runner (bin/cs-procevent.sh).
#
# Usage:
#   cs-procevent-lavish.sh arm <artifact.html>
#   cs-procevent-lavish.sh retire <artifact.html>
#   cs-procevent-lavish.sh source-id <artifact.html>
#   cs-procevent-lavish.sh classify <result-file>
#   cs-procevent-lavish.sh terminal <result-file>
#
# arm        Register this artifact's blocking `lavish-axi poll` with the runner
#            and print the source id to use with `cs-procevent.sh handled`.
# retire     Drop that registration and stop the poll this home owns.
# source-id  Print the canonical source id for an artifact.
# classify   Print the lifecycle state a handler should act on: feedback, ended,
#            waiting, missing, or unknown.
# terminal   Exit 0 when the captured result means this source will never produce
#            another result, so the runner may retire it; any other exit keeps it
#            armed. This is the generic adapter contract bin/cs-procevent.sh
#            calls, and the only place Lavish's notion of "ended" is decided.
#
# This adapter is deliberately thin. It owns only what is specific to Lavish:
# canonical source identity, the argv for the published poll command, and how to
# read a completed result. Ownership, durable capture, publication, and restart
# recovery all belong to bin/cs-procevent.sh.
#
# It wraps ONLY the currently published interface; docs/lavish.md records the
# verified commands, streams, and exit codes:
#   lavish-axi poll <html-file> [--agent-reply "..."]
# which long-polls indefinitely. The adapter therefore runs the plain blocking
# form with no timeout flag, so a result is a real server-side event, and it adds
# no periodic discovery and no timer fallback.
#
# LOSS LIMITATION, stated plainly. The published poll DESTRUCTIVELY clears
# feedback before returning it, so a result lost after that clearing and before
# the runner reads the process output is unrecoverable, and no wrapper here can
# close that source-side window. Never describe this path as at-least-once,
# no-loss, or lossless.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
  exit 2
}

artifact_realpath() {  # <artifact>
  perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$1" 2>/dev/null
}

# Canonical identity is PHYSICAL, not the path string: Lavish keys a session on
# the realpath of the artifact, so two names for one file are one source and must
# never become two owners racing destructive polls.
cmd_source_id() {
  local artifact=${1-} real
  [ -n "$artifact" ] || usage
  case "$artifact" in *$'\n'*) die "artifact paths cannot contain newlines" ;; esac
  real=$(artifact_realpath "$artifact") || die "cannot resolve the artifact path: $artifact"
  [ -f "$real" ] || die "artifact does not exist: $artifact"
  if command -v shasum >/dev/null 2>&1; then
    printf 'lavish-%s\n' "$(printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,16)}')"
  else
    printf 'lavish-%s\n' "$(printf '%s' "$real" | sha256sum | awk '{print substr($1,1,16)}')"
  fi
}

cmd_arm() {
  local artifact=${1-} id real
  [ -n "$artifact" ] || usage
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  id=$(cmd_source_id "$artifact") || exit 1
  real=$(artifact_realpath "$artifact") || die "cannot resolve the artifact path: $artifact"
  # The plain blocking form: no --timeout-ms, so completion is a server event.
  "$SCRIPT_DIR/cs-procevent.sh" register lavish "$id" -- lavish-axi poll "$real" || exit 1
  printf 'armed: %s\n' "$id"
  printf 'artifact: %s\n' "$real"
}

cmd_retire() {
  local artifact=${1-} id
  [ -n "$artifact" ] || usage
  id=$(cmd_source_id "$artifact") || exit 1
  "$SCRIPT_DIR/cs-procevent.sh" retire "$id"
}

# Read one field of the response's leading `session:` block. Those fields are
# INDENTED, so each is read as the first indented match inside that block rather
# than an anchored whole-line match; anchoring on "^status:" silently never
# matches and treats every ended review as feedback. Confining the read to the
# leading block is also what stops prompt payload text from forging a session
# field. <field> is a fixed name supplied by this adapter, never by input.
session_field() {  # <result-file> <field>
  awk -v field="$2" '
    $0 == "session:" { in_s=1; next }
    in_s && $0 !~ /^[[:space:]]/ { exit }
    in_s && $0 ~ "^[[:space:]]+" field ":[[:space:]]*[A-Za-z_]+[[:space:]]*$" {
      sub("^[[:space:]]+" field ":[[:space:]]*", ""); sub(/[[:space:]]*$/, ""); print; exit }
  ' "$1"
}

cmd_classify() {
  local file=${1-} status error_code error_message
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(session_field "$file" status)
  case "$status" in
    feedback) printf 'feedback\n'; return 0 ;;
    ended)    printf 'ended\n'; return 0 ;;
    waiting)  printf 'waiting\n'; return 0 ;;
  esac
  error_message=$(awk 'NR == 1 && /^error:[[:space:]]*/ { sub(/^error:[[:space:]]*/, ""); print }' "$file")
  error_code=$(awk '
    NR == 1 && /^error:[[:space:]]*/ { in_error=1; next }
    in_error && /^code:[[:space:]]*[A-Z_]+[[:space:]]*$/ {
      sub(/^code:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit }
    in_error { exit }
  ' "$file")
  if [ "$error_code" = NOT_FOUND ] || [[ "$error_message" == "No active Lavish Editor session"* ]]; then
    printf 'missing\n'
  else
    printf 'unknown\n'
  fi
}

# Whether a captured result ends this source, for the runner's automatic
# retirement. Lavish's notion of "ended" lives here and nowhere else: an ended
# session produces nothing further, a missing session has nothing left to
# produce, and the published poll delivers the final feedback of a `Send & End`
# review marked with session_ended and returns only empty ended sessions after
# it. Anything else - including an unreadable result - keeps the source armed.
cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  case "$(cmd_classify "$file")" in
    ended|missing) return 0 ;;
  esac
  case "$(session_field "$file" session_ended)" in
    true|True|TRUE) return 0 ;;
  esac
  return 1
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
