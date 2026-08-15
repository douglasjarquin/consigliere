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

# cs_herdr_argv_with_session <out-array-name> <session> <herdr arguments...>
# Populates <out-array-name> with argv plus --session <session> inserted
# immediately before a trailing "--" separator when one is present (e.g.
# `agent start ... -- AGENT_ARG...`), else appended at the end. Appending
# --session after a subcommand's own "--" would make it a literal passthrough
# arg instead of herdr's own session flag, resolving against the wrong
# session - the one shared implementation so this is fixed once, for every
# caller (cs_herdr below and bin/cs-herdr-lab.sh's cs_herdr_lab_raw), not
# reintroduced independently per caller.
cs_herdr_argv_with_session() {
  local -n _cs_herdr_argv_out=$1
  local session=$2
  shift 2
  local arg saw_sep=0
  _cs_herdr_argv_out=()
  for arg in "$@"; do
    if [ "$saw_sep" -eq 0 ] && [ "$arg" = "--" ]; then
      _cs_herdr_argv_out+=(--session "$session")
      saw_sep=1
    fi
    _cs_herdr_argv_out+=("$arg")
  done
  [ "$saw_sep" -eq 1 ] || _cs_herdr_argv_out+=(--session "$session")
}

cs_herdr() { # <herdr arguments...>
  local -a _cs_herdr_call_argv
  cs_herdr_argv_with_session _cs_herdr_call_argv "$(cs_herdr_session)" "$@"
  herdr "${_cs_herdr_call_argv[@]}"
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

cs_herdr_workspace_find() { # <label> -> workspace_id; rc=1 none, rc=2 ambiguous
  # Herdr enforces NO workspace-label uniqueness (docs/herdr.md), so a label is
  # a hint, never an identity. Returning the FIRST match silently binds a home
  # to whichever duplicate happens to come back first - the caller then operates
  # on a workspace the boss is not watching, with no signal that a choice was
  # even made. Two candidates refuse instead of adopting either.
  local label=$1 out ids n
  out=$(cs_herdr workspace list 2>/dev/null) || return 1
  ids=$(printf '%s' "$out" | jq -r --arg l "$label" \
    '.result.workspaces[] | select(.label == $l) | .workspace_id' 2>/dev/null)
  [ -n "$ids" ] || return 1
  n=$(printf '%s\n' "$ids" | grep -c .)
  if [ "$n" -gt 1 ]; then
    printf 'cs-herdr: workspace label "%s" matches %s workspaces (%s); refusing to guess which one is the home\n' \
      "$label" "$n" "$(printf '%s' "$ids" | tr '\n' ' ')" >&2
    return 2
  fi
  printf '%s\n' "$ids"
}

cs_herdr_home_workspace_ensure() { # <home-label> [cwd] -> workspace_id
  # Finds or creates the home workspace (label "consigliere" or "capo-<id>").
  # A created home workspace seeds a default tab; that root pane is the home
  # supervisor pane, so nothing is pruned here.
  #
  # An AMBIGUOUS label is a hard stop, not a create: adding a third workspace
  # with the same label would deepen the ambiguity, and adopting one of the two
  # would be the silent guess this refuses to make. The boss resolves it by
  # closing or relabelling the duplicate.
  local label=$1 cwd=${2:-$PWD} ws out rc=0
  ws=$(cs_herdr_workspace_find "$label") || rc=$?
  case $rc in
    0) printf '%s\n' "$ws"; return 0 ;;
    2) return 1 ;;
  esac
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
  # --lines N verified exact on 0.7.4 and 0.7.5; if the upstream truncation bug
  # reappears, re-add the read-wide-then-tail workaround here (docs/herdr.md).
  local pane=$1 lines=${2:-200} format=${3:-text}
  cs_herdr pane read "$pane" --lines "$lines" --format "$format"
}

cs_herdr_capture_detection() {
  local pane=$1 lines=${2:-200} format=${3:-text}
  cs_herdr pane read "$pane" --source detection --lines "$lines" --format "$format"
}

cs_herdr_run() { # <pane_id> <text>  - text plus Enter, atomic
  cs_herdr pane run "$1" "$2"
}

# cs_herdr_pane_run_confirmed <pane_id> <line> <timeout-ms> - like
# cs_herdr_run, but verifies <line> actually ran instead of trusting
# `pane run`'s return code, which reports success even when a not-yet-ready
# shell swallows the line. Appends a fresh per-call marker and confirms it
# with native `pane wait-output`, which searches existing scrollback first -
# so a stale marker from an earlier call on the same long-lived pane (a
# capo's home pane; a relaunch's second attempt) could otherwise false-match
# before the fresh line has actually run.
# The TYPED marker is quote-split ('CS''_...') so it never contains the
# matched string: the pty renders the typed line the moment the bytes arrive,
# before and independently of the shell executing it, so matching the typed
# spelling would confirm exactly the swallowed-line case this helper exists
# to catch. Only the shell EXECUTING the echo concatenates the halves into
# the string wait-output is asked for.
cs_herdr_pane_run_confirmed() {
  local pane=$1 line=$2 timeout_ms=$3 marker
  marker="CS_LINE_RAN_$$_${RANDOM}_${RANDOM}"
  cs_herdr_run "$pane" "$line; echo 'CS''${marker#CS}'" >/dev/null || return 1
  cs_herdr pane wait-output "$pane" --match "$marker" --timeout "$timeout_ms" >/dev/null 2>&1
}

# Agent-aware atomic submit-and-confirm. Preferred over cs_herdr_run for
# prompting an AGENT (rather than a shell): it delivers multiline text as ONE
# message instead of submitting at the first newline, and native `--wait
# --until working` (herdr 0.8.0+) folds the old separate submit-then-poll
# pattern into one call - herdr itself returns the distinct
# "agent_prompt_stalled" error (src/api/wait.rs, herdr source) when the agent
# never leaves its pre-submit state within its own 5s settle window, instead
# of consigliere polling `agent wait` a second time to find out.
# Still does NOT check the composer and will concatenate onto existing text.
# Two sanctioned callers: bin/cs-prompt-lib.sh's cs_prompt_guarded, which owns
# that composer guard, and bin/cs-spawn.sh's _cs_spawn_deliver_brief, which
# deliberately bypasses it because the guard's composer-empty check can never
# succeed on the fresh session its own spawn just created (rationale there and
# in docs/claude.md) - do not route that call site back through the guard.
cs_herdr_agent_prompt_confirmed() { # <pane_id> <text> [timeout-ms] -> rc 0 iff confirmed working
  cs_herdr agent prompt "$1" "$2" --wait --until working --timeout "${3:-8000}"
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

# The pane's own SHELL cwd. Verified live 2026-08-11 (herdr 0.7.5, protocol 17):
# `pane get` returns result.pane.cwd (the shell's directory) beside
# foreground_cwd (the foreground process's), both physically resolved, so a
# caller comparing against a recorded path must resolve that path too.
# rc 1 when unreported, which is "cannot tell" and never a mismatch.
cs_herdr_pane_cwd() { # <pane_id> -> absolute path, rc 1 when unreported
  local out
  out=$(cs_herdr pane get "$1" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -er '.result.pane.cwd // empty | select(. != "")' 2>/dev/null
}

# Classify one pane from the STRUCTURED response body, never from the exit
# status. `pane get` answers "no such pane", "here it is", and "I cannot tell
# you" over the same failure exit, and only the first is proof of death, so an
# exit-status reader like cs_herdr_pane_exists above folds an unreachable server
# into the same answer as a confirmed-absent pane. That fail-open reading is
# fine for callers that only want to skip work, and wrong for any caller about
# to destroy something on the strength of the answer.
#
# Verified live 2026-08-02 (herdr 0.7.5, protocol 17); exact bodies in
# docs/herdr.md "Pane presence":
#   present     -> {"result":{"pane":{"pane_id":"<id>",...}}}  on STDOUT, rc 0
#   absent      -> {"error":{"code":"pane_not_found",...}}     on STDERR, rc 1
#   unreachable -> non-JSON `Error: Os { code: 2, ... }`       on STDERR, rc 1
#
# The error body is on stderr, so a stdout-only read sees nothing at all for an
# absent pane and cannot tell it from an unreachable server. Both streams are
# captured together for that reason; if a future herdr ever mixed diagnostic
# noise into a success response the concatenation would stop parsing as JSON and
# classify unknown, which is the safe direction for every caller here.
cs_herdr_pane_presence() { # <pane_id> -> dead|present|unknown
  local out code echoed
  out=""
  # The body carries the answer even when the call exits non-zero (an absent
  # pane is rc 1 WITH a pane_not_found body), so the status is deliberately
  # discarded here rather than allowed to suppress the payload.
  if [ -n "${1:-}" ]; then
    out=$(cs_herdr pane get "$1" 2>&1) || true
  fi
  [ -n "$out" ] || { printf 'unknown\n'; return 0; }
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  code=$(printf '%s' "$out" | jq -r '.error.code // empty')
  if [ -n "$code" ]; then
    if [ "$code" = pane_not_found ]; then printf 'dead\n'; else printf 'unknown\n'; fi
    return 0
  fi
  # A success body must echo back the exact pane we asked about. Anything else -
  # a truncated result, a renamed field after a herdr upgrade - is not an answer.
  echoed=$(printf '%s' "$out" | jq -r '.result.pane.pane_id // empty')
  if [ "$echoed" = "$1" ]; then printf 'present\n'; else printf 'unknown\n'; fi
}

# Proof that the exact recorded pane is gone. Only a structured pane_not_found
# counts: present and unknown both refuse, so a caller can never treat "I could
# not reach herdr" as "the soldier is gone".
cs_herdr_pane_confirmed_gone() { # <pane_id>
  [ "$(cs_herdr_pane_presence "$1")" = dead ]
}

# --- agent status ----------------------------------------------------------

cs_herdr_agent_status_raw() { # <pane_id> -> idle|working|blocked|done|unknown
  local out
  out=$(cs_herdr agent get "$1" 2>/dev/null) || { printf 'unknown\n'; return 0; }
  printf '%s' "$out" | jq -r '.result.agent.agent_status // "unknown"'
}

# --- session snapshot ------------------------------------------------------
# One `api snapshot` carries EVERY pane's agent_status, agent, agent_session,
# cwd, tab/workspace ids, revision, and state_change_seq. A supervision cycle
# that reads N panes individually pays N round-trips for what one call already
# answered.
#
# Verified live (herdr 0.7.5, protocol 17): `herdr api snapshot` returns
# {"snapshot":{...},"type":...} with pane objects carrying the fields above.
cs_herdr_snapshot_fetch() { # -> raw JSON, rc 1 when unavailable
  local out
  out=$(cs_herdr api snapshot 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

# Pull one pane's field out of a snapshot already in hand. rc 1 when the pane is
# absent from it, which the caller must treat as "ask directly" rather than as a
# negative answer: a pane created since the snapshot is not a missing pane.
cs_herdr_snapshot_pane_field() { # <snapshot-json> <pane_id> <field>
  printf '%s' "$1" | jq -er --arg p "$2" --arg f "$3" '
    [ .. | objects | select(.pane_id? == $p) ] | first
    | select(. != null) | .[$f] // empty
  ' 2>/dev/null
}

# The corroboration policy itself, applied to a raw status obtained ANYWHERE -
# a per-pane `agent get` or a session snapshot. Split out so the policy has one
# owner no matter which transport produced the reading.
cs_herdr_busy_state_from_raw() { # <pane_id> <raw-status> -> busy|idle|blocked|done|unknown
  local pane=$1 raw=$2
  case "$raw" in
    working) printf 'busy\n'; return 0 ;;
    blocked) printf 'blocked\n'; return 0 ;;
    done)    printf 'done\n'; return 0 ;;
  esac
  if cs_herdr_capture "$pane" 40 text 2>/dev/null | grep -Eq "$CS_CODEX_BUSY_RE"; then
    printf 'busy\n'
    return 0
  fi
  printf '%s\n' "${raw:-unknown}"
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

# cs_herdr_agent_start_timeout_ms <seconds> - seconds converted to milliseconds
# for `agent start --timeout`, clamped to herdr's own documented ceiling
# (`herdr agent start --help`: max 300000). LAUNCH_WAIT and its
# CS_CONTROL_RESUME_WAIT_SECS sibling are boss-configurable with no upper
# bound, so a slow-machine or cautious override could exceed what herdr
# accepts; clamp with a loud note instead of letting the call fail or
# silently truncating without saying so.
CS_HERDR_AGENT_START_TIMEOUT_MAX_MS=300000
cs_herdr_agent_start_timeout_ms() {
  local secs=$1 normalized ms
  case "$secs" in
    ''|*[!0-9]*) return 1 ;;
  esac
  normalized=$secs
  while [ "${normalized#0}" != "$normalized" ]; do
    normalized=${normalized#0}
  done
  [ -n "$normalized" ] || normalized=0
  if [ "${#normalized}" -gt 3 ] ||
    { [ "${#normalized}" -eq 3 ] && [ "$normalized" -gt 300 ]; }; then
    echo "cs-herdr: clamping agent start --timeout from ${secs}s to herdr's ${CS_HERDR_AGENT_START_TIMEOUT_MAX_MS}ms ceiling" >&2
    ms=$CS_HERDR_AGENT_START_TIMEOUT_MAX_MS
  else
    # Force decimal interpretation: Bash treats a leading zero as octal.
    ms=$((10#$normalized * 1000))
  fi
  printf '%s' "$ms"
}

# cs_herdr_agent_start <pane_id> <name> <kind> <timeout-ms> <argv...> - native
# launch-and-wait-for-interactive_ready, replacing the cs_herdr_run +
# cs_herdr_agent_wait_present pair for an interactive agent (cold launch,
# capo, main ship/scout). Trailing <argv...> reaches the launched binary
# LITERALLY, with no shell evaluation - never pass a shell-quoted string here.
# On failure, reports herdr's own distinct error code (agent_pane_not_found,
# agent_kind_mismatch, agent_not_ready, agent_start_failed) instead of a
# generic timeout, so a caller's message can name what actually went wrong.
# Native names use disjoint namespaces: v- for short task ids already valid in
# Herdr's grammar, l- for longer valid task ids that need a digest, and n- for
# ids whose logical spelling must be normalized. These prefixes belong only to
# the native launch name; metadata, paths, and all other task identity remain
# keyed by the original logical task id.
cs_herdr_agent_name() {
  local logical=$1 name suffix keep digest namespace
  name=$(printf '%s' "$logical" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -c 'a-z0-9_-' '-')
  case "$name" in
    [a-z]*) ;;
    *) name="a-$name" ;;
  esac
  if [ "$name" = "$logical" ] && [ "${#name}" -le 30 ]; then
    printf 'v-%s' "$name"
    return 0
  fi
  namespace=n
  [ "$name" = "$logical" ] && namespace=l
  suffix=
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s' "$logical" | shasum -a 256 2>/dev/null) || digest=
    suffix=$(printf '%s\n' "$digest" | awk '{print substr($1,1,16)}')
  fi
  if [[ ! "$suffix" =~ ^[0-9a-f]{16}$ ]] && command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s' "$logical" | sha256sum 2>/dev/null) || digest=
    suffix=$(printf '%s\n' "$digest" | awk '{print substr($1,1,16)}')
  fi
  if [[ ! "$suffix" =~ ^[0-9a-f]{16}$ ]]; then
    echo "cs-herdr: shasum or sha256sum is required to derive a native agent name" >&2
    return 1
  fi
  keep=$((32 - ${#namespace} - 2 - ${#suffix}))
  printf '%s-%s-%s' "$namespace" "${name:0:keep}" "$suffix"
}

cs_herdr_agent_start() {
  local pane=$1 name=$2 kind=$3 timeout_ms=$4 out rc code
  shift 4
  name=$(cs_herdr_agent_name "$name") || return 1
  out=$(cs_herdr agent start "$name" --kind "$kind" --pane "$pane" --timeout "$timeout_ms" -- "$@" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] && return 0
  code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)
  case "$code" in
    agent_pane_not_found) echo "cs-herdr: agent start found no pane $pane" >&2 ;;
    agent_kind_mismatch) echo "cs-herdr: agent start detected the wrong agent kind in pane $pane (wanted $kind)" >&2 ;;
    agent_not_ready) echo "cs-herdr: agent in pane $pane never became interactive-ready within ${timeout_ms}ms" >&2 ;;
    agent_start_failed) echo "cs-herdr: agent start failed to launch in pane $pane: $out" >&2 ;;
    *) echo "cs-herdr: agent start failed for pane $pane: $out" >&2 ;;
  esac
  return 1
}

# cs_herdr_agent_wait_unblocked <pane_id> [timeout-secs] - 0 as soon as the
# pane's agent reads anything other than herdr's native `blocked`, 1 when it was
# still blocked for the whole window.
#
# `blocked` is herdr's native reading for "waiting on a HUMAN" - a trust dialog,
# an interactive menu, a login prompt - which is precisely the state an
# agent-presence check cannot distinguish from a working one: the agent is
# genuinely there, it just will never do anything. A settle window is required
# rather than a single read because a healthy launch passes through no blocked
# state at all, so any blocked reading that survives the window is the real
# thing rather than a startup transient.
cs_herdr_agent_wait_unblocked() { # <pane_id> [timeout-secs]
  local pane=$1 limit=${2:-10} waited=0
  while :; do
    [ "$(cs_herdr_agent_busy_state "$pane" 2>/dev/null)" = blocked ] || return 0
    [ "$waited" -lt "$limit" ] || return 1
    sleep 1
    waited=$((waited + 1))
  done
}

# --- agent session identity ------------------------------------------------
# The agent instance occupying a pane, as reported by herdr's official agent
# integrations (claude and codex are installed; `herdr integration status`
# lists them). It changes when a NEW agent instance takes the pane, so it turns
# "did this soldier restart?" from an inference into a fact:
#
#   same id across a wedge   -> the ORIGINAL agent is still sitting there, so a
#                               relaunch never happened and a "resumed" claim is
#                               false.
#   changed id               -> a different instance now owns the pane, so its
#                               context is not the one that was wedged.
#
# Verified live (herdr 0.7.5, protocol 17): pane objects carry agent_session as
# {"agent","kind","source","value"}; the value is the agent's own session id.
# Absent when no official integration reported one, which is not an error.
cs_herdr_agent_session_id() { # <pane_id> -> session value, rc 1 when unreported
  local out
  out=$(cs_herdr agent get "$1" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -er '
    .result.agent.agent_session.value // empty | select(. != "")
  ' 2>/dev/null
}

# Same identity from a snapshot already in hand, so a cycle that took one costs
# nothing extra.
cs_herdr_snapshot_agent_session() { # <snapshot-json> <pane_id>
  printf '%s' "$1" | jq -er --arg p "$2" '
    [ .. | objects | select(.pane_id? == $p) ] | first
    | select(. != null) | .agent_session.value // empty | select(. != "")
  ' 2>/dev/null
}

# Why herdr classified a pane's agent state as it did. Diagnostic only - the
# corroboration policy above exists because `agent get` alone was not trusted,
# and this is how a disagreement gets explained instead of guessed at.
cs_herdr_agent_explain() { # <pane_id> -> raw explain output
  cs_herdr agent explain "$1" 2>/dev/null
}

cs_herdr_agent_explain_file() {
  local capture=$1 agent=$2
  [ -f "$capture" ] && [ -r "$capture" ] || return 1
  cs_herdr agent explain --file "$capture" --agent "$agent" --verbose
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

# The flag is --until. herdr RENAMED it between releases: 0.7.4 took --status,
# 0.7.5 takes --until, and each rejects the other outright ("unknown option",
# exit 2). Consigliere shipped --status - correct for 0.7.4, recorded verified
# in docs/herdr.md - and herdr self-updated the fleet to 0.7.5 underneath it.
#
# What that cost: the only caller discards both streams, so a usage error read
# as "the turn never started". Every steer burned its full Enter-retry loop and
# reported "not confirmed" even when delivery had worked, and the away daemon's
# strict undelivered path was permanently on. CI never noticed because it pinned
# 0.7.4, where the old flag was still right.
#
# The pin tracks whatever bin/cs-install-herdr.sh currently pins (0.8.0 as of
# 2026-08-12, was 0.7.5), so CI exercises the same CLI contract the fleet
# runs, and tests/cs-herdr-lib-live.test.sh pins this flag against the real
# binary in the herdr lane.
cs_herdr_agent_wait() { # <pane_id> <status> <timeout-ms>
  cs_herdr agent wait "$1" --until "$2" --timeout "$3"
}

cs_herdr_submit_confirm() { # <pane_id> [timeout-ms]
  # After a send, confirm the receiving turn started: wait for working.
  cs_herdr_agent_wait "$1" working "${2:-8000}" >/dev/null 2>&1
}

# --- events ----------------------------------------------------------------
#
# Push events reach this fleet through herdr's own server-side plugin
# `[[events]]` hook, not through a subscriber consigliere runs: the hook writes
# each `pane.agent_status_changed` edge into a per-home spool
# (bin/cs-herdr-event-lib.sh) that the watcher drains. Nothing here connects to
# the control socket, so there is no capability probe to own.
