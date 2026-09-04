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
# (~/github/douglasjarquin/made/cmd/made/main.go) on 2026-08-13: only
# `made daemon start|stop|status`, `made status [--json] [run-id]`,
# `made review`, `made pr`, and `made doctor` existed in made's CLI dispatch
# switch then. Verified live on 2026-09-03: `made gate init
# <target-repo-path> <real-remote-url>` is a real, working subcommand today -
# ran it successfully against 18 separate project clones and confirmed
# `made doctor --json` reports `"gate":"initialized"` for each afterward
# (`gate init` prints `gate initialized at <path>/gate.git` on success).
# cs_made_gate_init below shells this command and is no longer a forward
# reference.
#
# One wrapper below is still a forward reference to a command made's CLI
# does not implement yet:
#
#   - cs_made_abort shells `made axi abort`. This is NOT a real made
#     subcommand and no task in plans/made-rewrite.md defines an `axi`
#     namespace for made at all - the name is carried over verbatim from the
#     predecessor tool's own `axi abort` convention (bin/cs-teardown.sh calls
#     cs_made_abort at its abort call site) as the closest known shape for
#     "abort the run parked at this gate". made's CLI may end up naming this
#     differently once it is actually built; if so, only this one function
#     needs to change and every caller stays correct.
#
# This forward-referencing wrapper exists now purely so Tasks 25-35 have a
# stable function name to call against; it starts working the moment made's
# CLI grows the matching subcommand, with no consigliere-side change needed.
#
# Requires: made, jq.

cs_made_require() {
  command -v made >/dev/null 2>&1 || { echo "cs-made: made is required" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "cs-made: jq is required" >&2; return 1; }
}

cs_made() { # <made arguments...>
  made "$@"
}

# `made status --json [run-id]` -> raw JSON, matching made's StatusReport
# schema (cmd/made/status.go: schema_version, run_id, repo, branch, state,
# queued_at, started_at, ended_at, error, stages[], pending_findings[]). With
# no run-id, made itself resolves the latest run. Callers parse fields with
# jq themselves (see Task 26's cs-crew-state.sh migration) rather than this
# function inventing its own parsed shape - matching cs-herdr-lib.sh's own
# pattern of raw-JSON primitives (e.g. cs_herdr_snapshot_fetch) plus
# caller-side jq extraction.
cs_made_status() { # [run-id] -> raw `made status --json` output
  if [ -n "${1:-}" ]; then
    cs_made status --json "$1"
  else
    cs_made status --json
  fi
}

cs_made_gate_init() { # [made gate init args...]
  cs_made gate init "$@"
}

cs_made_doctor() { # [made doctor args...]
  cs_made doctor "$@"
}

cs_made_daemon_start() { # [made daemon start args...]
  cs_made daemon start "$@"
}

cs_made_daemon_stop() { # [made daemon stop args...]
  cs_made daemon stop "$@"
}

# Abort the made run parked at the gate for [worktree-dir] (default: $PWD).
# The caller owns the redirection/fallback policy (e.g.
# `cs_made_abort "$WT" >/dev/null 2>&1 || true`); this only runs the command
# in the right directory. Forward reference to `made axi abort` - see header.
cs_made_abort() { # [worktree-dir]
  local wt=${1:-$PWD}
  ( cd "$wt" && cs_made axi abort )
}
