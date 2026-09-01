#!/usr/bin/env bash
# Provision and operate an isolated herdr lab session without risking the live
# default session.
#
# Usage:
#   cs-herdr-lab.sh name <label>
#   cs-herdr-lab.sh prepare <session>
#   cs-herdr-lab.sh provision <session>
#   cs-herdr-lab.sh run <session> <herdr arguments...>
#   cs-herdr-lab.sh stop <session>
#   cs-herdr-lab.sh teardown <session>
#
# Session names must begin with "cs-lab-" and can never be "default".
# Every herdr call made here carries --session <session>, placed by the
# shared cs_herdr_argv_with_session (bin/cs-herdr-lib.sh) so a caller's own
# trailing "--" argv separator is never mistaken for the session flag's home.
# The run command rejects caller-supplied --session flags, any leading option
# before the subcommand, all session lifecycle operations, and every server
# operation.
# Session stop is available only through guarded stop or teardown, and session
# delete is available only through teardown.
# Both paths perform a fresh refuse-default check immediately before each
# destructive call.
# Provision records the running default session as a fleet-state tripwire and
# teardown requires that record to be identical afterward.
#
# Ported from firstmate's fm-herdr-lab.sh; the guard structure is deliberate
# and safety-load-bearing - do not simplify it.
set -u

# shellcheck source=bin/cs-herdr-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cs-herdr-lib.sh"

cs_herdr_lab_error() {
  echo "cs-herdr-lab: $*" >&2
}

cs_herdr_lab_validate_name() { # <session>
  local name=${1:-}
  [[ "$name" =~ ^cs-lab-[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] && return 0
  case "$name" in
    default) cs_herdr_lab_error "refusing session name 'default'" ;;
    '') cs_herdr_lab_error "refusing an empty session name" ;;
    *) cs_herdr_lab_error "session name must start with 'cs-lab-' and contain only letters, digits, underscores, or dashes: $name" ;;
  esac
  return 1
}

cs_herdr_lab_state_dir() {
  printf '%s' "${CS_HERDR_LAB_STATE_DIR:-${TMPDIR:-/tmp}/cs-herdr-lab-${UID}}"
}

cs_herdr_lab_tripwire_path() { # <session>
  printf '%s/%s.fleet-state.json' "$(cs_herdr_lab_state_dir)" "$1"
}

cs_herdr_lab_raw() { # <session> <herdr arguments...>
  local name=$1
  shift
  cs_herdr_argv_with_session "$name" "$@"
  HERDR_SESSION="$name" herdr "${CS_HERDR_ARGV[@]}"
}

cs_herdr_lab_session_list() { # <session>
  cs_herdr_lab_raw "$1" session list --json
}

cs_herdr_lab_fleet_state() { # <session>
  local name=$1 sessions snapshot
  sessions=$(cs_herdr_lab_session_list "$name" 2>/dev/null) || {
    cs_herdr_lab_error "cannot read herdr sessions for the fleet-state tripwire"
    return 1
  }
  snapshot=$(printf '%s' "$sessions" | jq -c '
    [.sessions[]? | select(.default == true)]
    | if length == 1 and .[0].name == "default" and .[0].running == true
      then .[0] | {name, default, running, socket_path}
      else empty
      end
  ' 2>/dev/null)
  [ -n "$snapshot" ] || {
    cs_herdr_lab_error "fleet-state tripwire requires exactly one running default session"
    return 1
  }
  printf '%s\n' "$snapshot"
}

cs_herdr_lab_prepare() { # <session>
  local name=$1 sessions state_dir tripwire
  cs_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { cs_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { cs_herdr_lab_error "jq is required"; return 1; }

  sessions=$(cs_herdr_lab_session_list "$name" 2>/dev/null) || {
    cs_herdr_lab_error "cannot list herdr sessions before provisioning '$name'"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    cs_herdr_lab_error "session '$name' already exists; refusing to adopt or overwrite it"
    return 1
  fi

  state_dir=$(cs_herdr_lab_state_dir)
  tripwire=$(cs_herdr_lab_tripwire_path "$name")
  mkdir -p "$state_dir" || return 1
  [ ! -e "$tripwire" ] || {
    cs_herdr_lab_error "tripwire already exists for '$name'; refusing ambiguous ownership"
    return 1
  }
  cs_herdr_lab_fleet_state "$name" > "$tripwire" || {
    rm -f "$tripwire"
    return 1
  }
}

cs_herdr_lab_refuse_if_default() { # <session>
  local name=$1 info flag
  cs_herdr_lab_validate_name "$name" || return 1
  info=$(cs_herdr_lab_session_list "$name" 2>/dev/null) || {
    cs_herdr_lab_error "refusing destructive call because session list failed"
    return 1
  }
  flag=$(printf '%s' "$info" | jq -r --arg name "$name" \
    '.sessions[]? | select(.name == $name) | .default' 2>/dev/null)
  [ "$flag" = false ] && return 0
  cs_herdr_lab_error "refusing destructive call for '$name': session is absent or default (default=${flag:-<not found>})"
  return 1
}

cs_herdr_lab_cli() { # <session> <herdr arguments...>
  local name=$1 arg
  shift
  cs_herdr_lab_validate_name "$name" || return 1
  [ "$#" -gt 0 ] || { cs_herdr_lab_error "run requires herdr arguments"; return 1; }
  case "$1" in
    -*)
      cs_herdr_lab_error "run forbids a leading option before the herdr subcommand; it could shift a server or session lifecycle operation past the guard or subvert session isolation"
      return 1
      ;;
  esac
  for arg in "$@"; do
    case "$arg" in
      --session|--session=*)
        cs_herdr_lab_error "run forbids caller-supplied --session; the helper appends the lab session"
        return 1
        ;;
    esac
  done
  case "$1 ${2:-}" in
    "server "*)
      cs_herdr_lab_error "run forbids server operations; use provision for the named lab server"
      return 1
      ;;
    "session list") ;;
    "session "*)
      cs_herdr_lab_error "run forbids session lifecycle operations; use guarded teardown"
      return 1
      ;;
  esac
  cs_herdr_lab_raw "$name" "$@"
}

cs_herdr_lab_cancel_provision() { # <pid>
  local pid=$1 attempt=0
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt 10 ]; do
      sleep 0.1
      attempt=$((attempt + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
}

cs_herdr_lab_provision() { # <session>
  local name=$1 sessions tripwire running attempt server_pid max_attempts timeout_seconds
  cs_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { cs_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { cs_herdr_lab_error "jq is required"; return 1; }

  sessions=$(cs_herdr_lab_session_list "$name" 2>/dev/null) || {
    cs_herdr_lab_error "cannot list herdr sessions before provisioning '$name'"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    tripwire=$(cs_herdr_lab_tripwire_path "$name")
    [ -f "$tripwire" ] || {
      cs_herdr_lab_error "missing fleet-state tripwire for existing session '$name'; refusing to adopt it"
      return 1
    }
    cs_herdr_lab_refuse_if_default "$name" || return 1
    running=$(printf '%s' "$sessions" | jq -r --arg name "$name" \
      '.sessions[]? | select(.name == $name) | .running' 2>/dev/null)
    [ "$running" = false ] || {
      cs_herdr_lab_error "session '$name' is not stopped; refusing to re-provision it"
      return 1
    }
    cs_herdr_lab_check_tripwire "$name" || return 1
  else
    cs_herdr_lab_prepare "$name" || return 1
  fi
  cs_herdr_lab_raw "$name" server >/dev/null 2>&1 &
  server_pid=$!
  attempt=0
  max_attempts=300
  timeout_seconds=60
  while [ "$attempt" -lt "$max_attempts" ]; do
    running=$(cs_herdr_lab_cli "$name" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null) || running=false
    if [ "$running" = true ]; then
      cs_herdr_lab_refuse_if_default "$name" || {
        cs_herdr_lab_cancel_provision "$server_pid"
        return 1
      }
      return 0
    fi
    sleep 0.2
    attempt=$((attempt + 1))
  done
  cs_herdr_lab_cancel_provision "$server_pid"
  cs_herdr_lab_error "lab session '$name' did not report running within $timeout_seconds seconds"
  return 1
}

cs_herdr_lab_check_tripwire() { # <session>
  local name=$1 tripwire before after
  tripwire=$(cs_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    cs_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing unverified teardown"
    return 1
  }
  before=$(cat "$tripwire")
  after=$(cs_herdr_lab_fleet_state "$name") || return 1
  [ "$before" = "$after" ] || {
    cs_herdr_lab_error "FLEET-STATE TRIPWIRE FAILED: default session changed during lab work"
    cs_herdr_lab_error "before: $before"
    cs_herdr_lab_error "after:  $after"
    return 1
  }
}

cs_herdr_lab_verify_tripwire() { # <session>
  local name=$1 tripwire
  cs_herdr_lab_check_tripwire "$name" || return 1
  tripwire=$(cs_herdr_lab_tripwire_path "$name")
  rm -f "$tripwire"
}

cs_herdr_lab_stop() { # <session>
  local name=$1 tripwire
  cs_herdr_lab_validate_name "$name" || return 1
  tripwire=$(cs_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    cs_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing stop"
    return 1
  }
  cs_herdr_lab_refuse_if_default "$name" || return 1
  cs_herdr_lab_raw "$name" session stop "$name" --json
}

cs_herdr_lab_teardown() { # <session>
  local name=$1 tripwire sessions delete_status=0
  cs_herdr_lab_validate_name "$name" || return 1
  tripwire=$(cs_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    cs_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing destructive calls"
    return 1
  }
  sessions=$(cs_herdr_lab_session_list "$name" 2>/dev/null) || {
    cs_herdr_lab_error "cannot list herdr sessions before teardown"
    return 1
  }
  if ! printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    cs_herdr_lab_verify_tripwire "$name"
    return
  fi
  cs_herdr_lab_stop "$name" >/dev/null 2>&1 || true
  sleep 0.5
  cs_herdr_lab_refuse_if_default "$name" || return 1
  cs_herdr_lab_raw "$name" session delete "$name" --json >/dev/null 2>&1 || delete_status=$?
  sessions=$(cs_herdr_lab_session_list "$name" 2>/dev/null) || {
    cs_herdr_lab_error "cannot confirm removal of lab session '$name' after teardown"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    if [ "$delete_status" -ne 0 ]; then
      cs_herdr_lab_error "session delete failed for '$name' and the lab session remains"
    else
      cs_herdr_lab_error "lab session '$name' remains after teardown"
    fi
    return 1
  fi
  cs_herdr_lab_verify_tripwire "$name"
}

cs_herdr_lab_name() { # <label>
  local label=${1:-lab}
  label=$(printf '%s' "$label" | tr -cd 'a-zA-Z0-9_-' | sed 's/^[^a-zA-Z0-9]*//; s/-*$//')
  [ -n "$label" ] || label=lab
  label=${label:0:16}
  label=${label%-}
  [ -n "$label" ] || label=lab
  printf 'cs-lab-%s-%s-%s\n' "$label" "$$" "$RANDOM"
}

cs_herdr_lab_usage() {
  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

cs_herdr_lab_main() {
  local command=${1:-}
  case "$command" in
    name)
      [ "$#" -eq 2 ] || { cs_herdr_lab_usage >&2; return 2; }
      cs_herdr_lab_name "$2"
      ;;
    prepare)
      [ "$#" -eq 2 ] || { cs_herdr_lab_usage >&2; return 2; }
      cs_herdr_lab_prepare "$2"
      ;;
    provision)
      [ "$#" -eq 2 ] || { cs_herdr_lab_usage >&2; return 2; }
      cs_herdr_lab_provision "$2"
      ;;
    run)
      [ "$#" -ge 3 ] || { cs_herdr_lab_usage >&2; return 2; }
      shift
      cs_herdr_lab_cli "$@"
      ;;
    stop)
      [ "$#" -eq 2 ] || { cs_herdr_lab_usage >&2; return 2; }
      cs_herdr_lab_stop "$2"
      ;;
    teardown)
      [ "$#" -eq 2 ] || { cs_herdr_lab_usage >&2; return 2; }
      cs_herdr_lab_teardown "$2"
      ;;
    -h|--help|help)
      cs_herdr_lab_usage
      ;;
    *)
      cs_herdr_lab_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -e
  cs_herdr_lab_main "$@"
fi
