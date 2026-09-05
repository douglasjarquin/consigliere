#!/usr/bin/env bash
# cs-made-lib.sh - the one made-CLI layer for consigliere.
#
# Sourced, never executed. Thin wrappers only: no made-specific logic belongs
# in cs-crew-state.sh/cs-watch.sh/cs-teardown.sh/etc - those scripts call
# through here instead, mirroring cs-herdr-lib.sh's separation of concerns for
# herdr (bin/cs-herdr-lib.sh).
#
# made (github.com/douglasjarquin/made) has no session concept the way herdr
# does, so there is no analogous session-scoping helper here (contrast
# cs-herdr-lib.sh's cs_herdr_session) - every function below is a direct,
# unscoped shellout to the made CLI.
#
# CLI-surface note, verified against made's own source
# (~/github/douglasjarquin/made, HEAD ebc2fa0df816a14bdf2d17847d04a16fbca43576)
# on 2026-09-05: made's real command surface is `run list|status|cancel|submit`,
# `review decide`, `doctor`, `daemon start|stop|status`, `gate init`, `verify`,
# `validate`, `plan`, `capabilities`, `config`, `receipts`, `cursor` - there is
# no `axi` family anywhere. `axi` (run/status/abort/respond/sync/logs) belongs
# to the predecessor tool `no-mistakes`, not made; made's own planning docs
# explicitly call it a deferred, never-built forward reference. See
# docs/made.md for the full verified-facts record (exact flags, JSON shapes,
# and live command transcripts) that every function below is cited against.
#
# Requires: made, jq.

CS_MADE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cs_made_require() {
  command -v made >/dev/null 2>&1 || { echo "cs-made: made is required" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "cs-made: jq is required" >&2; return 1; }
}

cs_made() { # <made arguments...>
  made "$@"
}

# cs_made_status <run-id> -> raw `made run status --json <run-id>` output, one
# StatusReport JSON object (docs/made.md: run_id, repo, branch, state,
# input_sha, output_sha, execution_finished, pr_url, error, errors[],
# stages[], pending_findings[], ...). run-id is REQUIRED: made's run.status
# RPC takes an exact id, no prefix match and no "latest" (unlike the old,
# obsolete bare `made status` this replaces). Callers parse fields with jq
# themselves, matching cs-herdr-lib.sh's raw-JSON-primitive pattern.
cs_made_status() { # <run-id>
  cs_made_require || return 1
  [ -n "${1:-}" ] || { echo "cs_made_status: run-id required" >&2; return 1; }
  cs_made run status --json "$1"
}

# cs_made_run_list [--active] -> raw `made run list --json [--active]` output,
# {"schema_version":1,"protocol_version":1,"runs":[StatusReport, ...]}.
# --active filters to made's own activeRunStatus(): queued/running/
# awaiting_review/awaiting_merge only, excluding succeeded/failed/canceled/
# superseded (docs/made.md).
cs_made_run_list() { # [--active]
  cs_made_require || return 1
  case "${1:-}" in
    ''|--active) : ;;
    *) echo "cs_made_run_list: unknown argument: $1" >&2; return 1 ;;
  esac
  cs_made run list --json "$@"
}

# cs_made_run_cancel <run-id> -> raw `made run cancel --json <run-id>` output.
# Callers (bin/cs-teardown.sh) must not call this against a run already in
# awaiting_merge or any terminal state (succeeded/failed/canceled/
# superseded): made run cancel against awaiting_merge hangs ~5s then errors
# (docs/made.md), since that run's work-goroutine has already finished. Only
# call this for queued/running/awaiting_review. This function itself is a
# thin, unconditional wrapper - it does not decide whether cancelling is
# safe; that policy lives in the caller.
cs_made_run_cancel() { # <run-id>
  cs_made_require || return 1
  [ -n "${1:-}" ] || { echo "cs_made_run_cancel: run-id required" >&2; return 1; }
  cs_made run cancel --json "$1"
}

# cs_made_review_decide <run-id> <stage> <approved|rejected> -> raw
# `made review decide --json --stage <stage> --decision <decision> <run-id>`
# output. Only "review" and "document" stages ever park (docs/made.md); a
# rejected decision FAILS the run, made never auto-fixes on reject. decision
# is validated client-side before shelling out, matching made's own daemon-
# side validation (docs/made.md).
cs_made_review_decide() { # <run-id> <stage> <approved|rejected>
  cs_made_require || return 1
  local run_id=$1 stage=$2 decision=$3
  if [ -z "$run_id" ] || [ -z "$stage" ]; then
    echo "cs_made_review_decide: run-id and stage required" >&2
    return 1
  fi
  case "$decision" in
    approved|rejected) : ;;
    *)
      echo "cs_made_review_decide: decision must be approved or rejected, got: $decision" >&2
      return 1
      ;;
  esac
  cs_made review decide --json --stage "$stage" --decision "$decision" "$run_id"
}

cs_made_gate_init() { # [made gate init args...]
  cs_made gate init "$@"
}

cs_made_doctor() { # [made doctor args...]
  cs_made doctor "$@"
}

# cs_made_daemon_start [log-path] [timeout-seconds]
# `made daemon start` blocks in the foreground until stopped (no self-
# daemonization anywhere in made's source, docs/made.md) - detach it the same
# way bin/cs-monitor-lib.sh's cs_monitor_ensure detaches the monitor
# (bin/cs-detach.py double-fork via setsid(2); nohup+disown fallback when
# python3 is missing), then poll `made doctor --json`'s .checks.daemon until
# "reachable" or the bound elapses. log-path defaults to /dev/null;
# timeout-seconds defaults to 30. Returns 0 once reachable, including an
# immediate 0 if it was already reachable - never starts a second daemon.
# Never call this to restart/replace an already-reachable daemon - it is a
# shared instance serving every lane/home; only consigliere's root session
# calls this (bin/cs-bootstrap.sh), never a soldier.
cs_made_daemon_start() { # [log-path] [timeout-seconds]
  cs_made_require || return 1
  local log=${1:-/dev/null} timeout=${2:-30} detach i=0 bound
  _cs_made_doctor_daemon_reachable && return 0
  detach="$CS_MADE_LIB_DIR/cs-detach.py"
  if [ -x "$detach" ] && command -v python3 >/dev/null 2>&1; then
    python3 "$detach" --stdout "$log" -- made daemon start >/dev/null 2>&1
  else
    nohup made daemon start >>"$log" 2>&1 &
    disown 2>/dev/null || true
  fi
  case "$timeout" in ''|*[!0-9]*) timeout=30 ;; esac
  bound=$((timeout * 2))
  while [ "$i" -lt "$bound" ]; do
    _cs_made_doctor_daemon_reachable && return 0
    sleep 0.5
    i=$((i + 1))
  done
  echo "cs_made_daemon_start: made daemon did not become reachable within ${timeout}s; see $log" >&2
  return 1
}

# 0 iff `made doctor --json`'s .checks.daemon is exactly "reachable".
_cs_made_doctor_daemon_reachable() {
  local j
  j=$(made doctor --json 2>/dev/null) || return 1
  [ -n "$j" ] || return 1
  [ "$(printf '%s' "$j" | jq -r '.checks.daemon // empty' 2>/dev/null)" = reachable ]
}

cs_made_daemon_stop() { # [made daemon stop args...]
  cs_made daemon stop "$@"
}
