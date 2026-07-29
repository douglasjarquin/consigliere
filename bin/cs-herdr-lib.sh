#!/usr/bin/env bash
# cs-herdr-lib.sh - the one herdr layer for consigliere.
#
# Sourced, never executed. Every function talks to herdr with an explicit
# trailing --session so ambient HERDR_SESSION can never redirect a call
# (verified unreliable upstream once a second server runs).
#
# Verified facts and the workspace-per-task container shape live in
# docs/herdr.md; re-verify that file before changing behavior here.
#
# Session resolution: CS_HERDR_SESSION when set (labs set it), else "default".
# Requires: herdr >= protocol 16, jq.
#
# Status policy (docs/herdr.md "Native agent status"):
#   native working  -> busy, trusted outright
#   native blocked  -> blocked, always surfaced by callers
#   native done     -> done
#   native idle/unknown -> corroborated against CS_CODEX_BUSY_RE on the
#     rendered pane before a caller may treat the soldier as not working,
#     because agent.get can read idle during a long foreground tool call.

CS_HERDR_MIN_PROTOCOL=16
# The rendered-banner busy signature used to corroborate a native idle/unknown
# reading. codex and claude both render "esc to interrupt" during a live turn, so
# one constant covers both harnesses. CS_CODEX_BUSY_RE is kept as a back-compat
# alias for existing readers (cs-watch, cs-crew-state). One owner; do not add
# per-model variants (cs-harness-lib.sh's cs_harness_busy_re is the seam if a
# harness ever diverges).
CS_HARNESS_BUSY_RE='[Ee]sc to interrupt'
CS_CODEX_BUSY_RE="$CS_HARNESS_BUSY_RE"

cs_herdr_session() {
  printf '%s' "${CS_HERDR_SESSION:-default}"
}

cs_herdr() { # <herdr arguments...>
  herdr "$@" --session "$(cs_herdr_session)"
}

cs_herdr_require() {
  command -v herdr >/dev/null 2>&1 || { echo "cs-herdr: herdr is required" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "cs-herdr: jq is required" >&2; return 1; }
}

cs_herdr_protocol_check() {
  local status proto
  cs_herdr_require || return 1
  status=$(cs_herdr status --json 2>/dev/null) || {
    echo "cs-herdr: cannot read herdr status for session '$(cs_herdr_session)'" >&2
    return 1
  }
  proto=$(printf '%s' "$status" | jq -r '.server.protocol // empty')
  [ -n "$proto" ] && [ "$proto" -ge "$CS_HERDR_MIN_PROTOCOL" ] 2>/dev/null && return 0
  echo "cs-herdr: server protocol '${proto:-absent}' below required $CS_HERDR_MIN_PROTOCOL" >&2
  return 1
}

# --- workspaces ------------------------------------------------------------

cs_herdr_workspace_find() { # <label> -> workspace_id or rc=1
  local label=$1 out id
  out=$(cs_herdr workspace list 2>/dev/null) || return 1
  id=$(printf '%s' "$out" | jq -r --arg l "$label" \
    '[.result.workspaces[] | select(.label == $l) | .workspace_id] | first // empty' 2>/dev/null)
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

cs_herdr_home_workspace_ensure() { # <home-label> [cwd] -> workspace_id
  # Finds or creates the home workspace (label "consigliere" or "capo-<id>").
  # A created home workspace seeds a default tab; that root pane is the home
  # supervisor pane, so nothing is pruned here.
  local label=$1 cwd=${2:-$PWD} ws out
  ws=$(cs_herdr_workspace_find "$label") && { printf '%s\n' "$ws"; return 0; }
  out=$(cs_herdr workspace create --cwd "$cwd" --label "$label" --no-focus) || return 1
  printf '%s' "$out" | jq -re '.result.workspace.workspace_id'
}

cs_herdr_workspace_exists() { # <workspace_id>
  cs_herdr workspace list 2>/dev/null \
    | jq -e --arg id "$1" '.result.workspaces[] | select(.workspace_id == $id)' >/dev/null 2>&1
}

cs_herdr_workspace_root_pane() { # <workspace_id> -> first pane_id in workspace
  local id
  id=$(cs_herdr pane list 2>/dev/null | jq -r --arg w "$1" \
    '[.result.panes[] | select(.workspace_id == $w) | .pane_id] | first // empty')
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

# --- task worktrees (workspace-per-task) -----------------------------------

cs_herdr_task_create() { # <project-path> <branch> <task-label> [base-ref]
  # Creates the task worktree + its own workspace, sourcing the repo from the
  # project path (--cwd) so no workspace needs to be open on the project.
  # Prints TAB-separated: workspace_id  pane_id  worktree_path  branch
  # The root pane IS the task pane (docs/herdr.md); no default-tab prune.
  local src=$1 branch=$2 label=$3 base=${4:-} out
  if [ -n "$base" ]; then
    out=$(cs_herdr worktree create --cwd "$src" --branch "$branch" --base "$base" --label "$label" --no-focus) || return 1
  else
    out=$(cs_herdr worktree create --cwd "$src" --branch "$branch" --label "$label" --no-focus) || return 1
  fi
  printf '%s' "$out" | jq -re \
    '.result | [.workspace.workspace_id, .root_pane.pane_id, .worktree.path, .worktree.branch] | @tsv'
}

cs_herdr_worktree_open() { # <path> <label> -> same TAB-separated tuple
  # Recovery path for a surviving worktree whose workspace is gone.
  local path=$1 label=$2 out
  out=$(cs_herdr worktree open --path "$path" --label "$label" --no-focus) || return 1
  printf '%s' "$out" | jq -re \
    '.result | [.workspace.workspace_id, .root_pane.pane_id, .worktree.path, .worktree.branch] | @tsv'
}

cs_herdr_worktree_remove() { # <workspace_id> [--force]
  # Dirty worktrees fail closed upstream (dirty_worktree_requires_force).
  # cs-teardown's landed-work proofs run BEFORE this; --force is passed only
  # on an explicit boss-authorized discard.
  local ws=$1 force=${2:-}
  if [ "$force" = "--force" ]; then
    cs_herdr worktree remove --workspace "$ws" --force
  else
    cs_herdr worktree remove --workspace "$ws"
  fi
}

cs_herdr_worktree_list() { # <repo-or-worktree-path> -> JSON
  cs_herdr worktree list --cwd "$1"
}

# --- panes -----------------------------------------------------------------

cs_herdr_capture() { # <pane_id> [lines] [format]
  # --lines N verified exact on 0.7.4; if the upstream truncation bug
  # reappears, re-add the read-wide-then-tail workaround here (docs/herdr.md).
  local pane=$1 lines=${2:-200} format=${3:-text}
  cs_herdr pane read "$pane" --lines "$lines" --format "$format"
}

cs_herdr_run() { # <pane_id> <text>  - text plus Enter, atomic
  cs_herdr pane run "$1" "$2"
}

cs_herdr_send_text() { # <pane_id> <text>  - literal, no submit
  cs_herdr pane send-text "$1" "$2"
}

cs_herdr_send_keys() { # <pane_id> <keys...>
  local pane=$1
  shift
  cs_herdr pane send-keys "$pane" "$@"
}

cs_herdr_pane_close() { # <pane_id>
  cs_herdr pane close "$1"
}

cs_herdr_pane_exists() { # <pane_id>
  cs_herdr pane get "$1" >/dev/null 2>&1
}

# --- agent status ----------------------------------------------------------

cs_herdr_agent_status_raw() { # <pane_id> -> idle|working|blocked|done|unknown
  local out
  out=$(cs_herdr agent get "$1" 2>/dev/null) || { printf 'unknown\n'; return 0; }
  printf '%s' "$out" | jq -r '.result.agent.agent_status // "unknown"'
}

cs_herdr_agent_busy_state() { # <pane_id> -> busy|idle|blocked|done|unknown
  # Applies the corroboration policy: idle/unknown re-checks the rendered
  # busy signature so a long foreground tool call is never read as stopped.
  local pane=$1 raw
  raw=$(cs_herdr_agent_status_raw "$pane")
  case "$raw" in
    working) printf 'busy\n'; return 0 ;;
    blocked) printf 'blocked\n'; return 0 ;;
    done)    printf 'done\n'; return 0 ;;
  esac
  if cs_herdr_capture "$pane" 40 text 2>/dev/null | grep -Eq "$CS_CODEX_BUSY_RE"; then
    printf 'busy\n'
    return 0
  fi
  printf '%s\n' "$raw"
}

cs_herdr_agent_alive() { # <pane_id>  - is a real agent (codex or claude) in the pane?
  local out
  out=$(cs_herdr agent get "$1" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e '.result.agent.agent // empty | select(. != "")' >/dev/null 2>&1
}

# --- pane process evidence -------------------------------------------------
# `agent get` reports what herdr BELIEVES about a pane's agent; process-info
# reports what is actually running in it. The two answer different questions,
# and the gap between them is where a wedge hides: an agent that exited leaves a
# pane whose agent_status reads idle or unknown, indistinguishable by status
# alone from an agent that is simply between turns.
#
# Verified live (herdr 0.7.5, protocol 17): `pane process-info --pane <id>`
# returns result.process_info with shell_pid and foreground_processes[], each
# carrying pid, argv0, argv, cmdline, and cwd. Note the flag form: the pane is
# passed as `--pane <id>`, NOT positionally.
cs_herdr_pane_process_info() { # <pane_id> -> raw JSON
  cs_herdr pane process-info --pane "$1" 2>/dev/null
}

# Print "<pid>\t<argv0>" for a supported agent running in the pane's foreground,
# rc 1 when no agent process is there. rc 1 with a readable pane is the
# interesting case: the pane survives, the agent does not.
cs_herdr_pane_agent_process() { # <pane_id> -> <pid>\t<argv0>, rc 1 if absent
  local out
  out=$(cs_herdr_pane_process_info "$1") || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out" | jq -er '
    .result.process_info.foreground_processes // []
    | map(select((.argv0 // "") | test("^(codex|claude)$")))
    | first
    | select(. != null)
    | "\(.pid)\t\(.argv0)"
  ' 2>/dev/null
}

# 0 when the pane is readable, its process table was READ SUCCESSFULLY, and no
# agent process is running in it - a husk left behind by an agent that exited.
#
# Fails closed on purpose. "Could not read the process table" and "read it, no
# agent there" are completely different claims, and only the second is a husk.
# Treating an unreadable answer as a husk would report a healthy soldier as dead
# on any herdr that lacks process-info, any transient socket error, and every
# test stub - the loudest possible wrong answer. So the process_info object with
# its foreground_processes array must actually be present before this concludes
# anything.
cs_herdr_pane_is_agent_husk() { # <pane_id>
  local out
  cs_herdr_pane_exists "$1" || return 1
  out=$(cs_herdr_pane_process_info "$1") || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out" \
    | jq -e '.result.process_info.foreground_processes | arrays' >/dev/null 2>&1 || return 1
  cs_herdr_pane_agent_process "$1" >/dev/null 2>&1 && return 1
  return 0
}

cs_herdr_agent_wait() { # <pane_id> <status> <timeout-ms>
  cs_herdr agent wait "$1" --status "$2" --timeout "$3"
}

cs_herdr_submit_confirm() { # <pane_id> [timeout-ms]
  # After a send, confirm the receiving turn started: wait for working.
  cs_herdr_agent_wait "$1" working "${2:-8000}" >/dev/null 2>&1
}

# --- events ----------------------------------------------------------------

cs_herdr_socket_path() {
  cs_herdr status --json 2>/dev/null | jq -r '.server.socket // empty'
}

cs_herdr_events_capable() {
  local sock
  command -v python3 >/dev/null 2>&1 || return 1
  sock=$(cs_herdr_socket_path)
  [ -n "$sock" ] && [ -S "$sock" ]
}
