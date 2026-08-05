#!/usr/bin/env bash
# cs-crew-state.sh - deterministic read of a soldier's CURRENT state.
#
# Why this exists: state/<id>.status is an append-only, best-effort EVENT LOG.
# Soldiers append only wake-worthy transitions
# (done/needs-decision/needs-review/blocked/paused/failed)
# and nothing when they silently resume, so `tail -1` of that log reports the
# last EVENT, not the current STATE. After consigliere resolves a needs-decision
# or blocked and the soldier resumes (responds to the gate, the pipeline fixes,
# it re-validates), the log's last line stays stale. This helper never infers
# the current state from a tail of the log: it reads the authoritative source
# (a no-mistakes run-step attributed to this soldier's branch and current code
# identity, else the pane busy-signature) and reconciles the possibly-stale log
# against it.
#
# The local reconciliation is deterministic - only run-step / pane / log reads
# plus fixed mapping logic, no heuristics and no LLM. The shared no-mistakes run
# attribution and gate-parked predicates live in bin/cs-nm-run-lib.sh, their one
# owner for this reader and teardown. Output is one stable, parseable,
# token-tight line consigliere can read every heartbeat:
#
#   state: <working|parked|done|blocked|paused|failed|unknown> · source: <run-step|pane|status-log|pane-process|none> · <detail>
#
# Logic, in order:
#   1. Resolve worktree + pane + kind from state/<id>.meta.
#   2. Resolve a no-mistakes run for this soldier's branch and current code
#      identity through bin/cs-nm-run-lib.sh, using `axi status` or the coarse
#      `no-mistakes runs` fallback. The library owns the exact attribution and
#      gate-parked predicates used here and by teardown.
#      The run-step is AUTHORITATIVE: running/fixing -> working, ci -> working,
#      awaiting_approval/fix_review -> parked (with gate findings), terminal
#      passed/checks-passed -> done, failed/cancelled -> failed. EXCEPT: while
#      the active step is ci, `axi status` alone cannot tell "still waiting on
#      checks" from "checks green, waiting on merge" (see nm_ci_checks_state) -
#      a ci-step log-tail check overrides working -> done once checks read
#      green, so a green PR is never silently read as still-validating.
#   3. Reconcile the status log: if its last line says needs-decision/blocked but
#      the run-step shows the run moved on, the log is deterministically stale and
#      is flagged superseded. A genuinely parked run plus a needs-decision log
#      agree, and are reported as parked.
#   4. No run for this soldier (pre-validation, or kind=scout): fall back to the
#      recorded pane's busy state, then the status log's last line only when its
#      verb maps to a recognized run-state. Decision-only events such as
#      `resolved` never become current state or detail.
#   5. Missing meta or torn-down worktree: report unknown · none. If no run is
#      attributed to this soldier, a dead pane also reports unknown · none rather
#      than trusting a stale status log.
#
# Read-only and side-effect free. Always exits 0 on a successful read regardless
# of state; exit 2 only on a usage error (no id).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root

# shellcheck source=bin/cs-herdr-lib.sh
. "$SCRIPT_DIR/cs-herdr-lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$SCRIPT_DIR/cs-meta-lib.sh"
# shellcheck source=bin/cs-classify-lib.sh
. "$SCRIPT_DIR/cs-classify-lib.sh"
# shellcheck source=bin/cs-nm-run-lib.sh
. "$SCRIPT_DIR/cs-nm-run-lib.sh"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: cs-crew-state.sh <id>" >&2; exit 2; }

META="$STATE/$ID.meta"
LOG="$STATE/$ID.status"
NM_TIMEOUT=${CS_CREW_STATE_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac
# How many of the most recent `no-mistakes runs` rows the cross-branch fallback
# (nm_runs_status_for_branch, below) scans. Generous enough to still find a
# branch's own run on a busy multi-soldier fleet without listing the entire
# history every call.
CS_CREW_STATE_RUNS_LIMIT=${CS_CREW_STATE_RUNS_LIMIT:-200}
case "$CS_CREW_STATE_RUNS_LIMIT" in ''|*[!0-9]*) CS_CREW_STATE_RUNS_LIMIT=200 ;; esac
SEP=' · '

# Emit the one canonical line and exit 0. Detail is optional.
emit() {  # <state> <source> [detail]
  local line="state: $1${SEP}source: $2"
  [ -n "${3:-}" ] && line="$line${SEP}$3"
  printf '%s\n' "$line"
  exit 0
}

# --- meta resolution --------------------------------------------------------

[ -f "$META" ] || emit unknown none "no metadata for $ID"

WT=$(cs_meta_get "$META" worktree || true)
KIND=$(cs_meta_get "$META" kind || echo ship)
[ -n "$KIND" ] || KIND=ship

# A torn-down (or never-created) worktree has no current state to read.
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  emit unknown none "worktree gone (torn down?)"
fi

# --- status log ------------------------------------------------------------

# Last non-empty status line, and its leading verb (the word before the colon).
log_last_line() {
  [ -f "$LOG" ] || return 1
  grep -v '^[[:space:]]*$' "$LOG" 2>/dev/null | tail -1
}
# Map a status-log verb onto a canonical state for the fallback path. `paused` is
# the deliberate-external-wait verb (cs-classify-lib.sh's CS_CLASSIFY_PAUSED_VERB):
# a soldier with no active run and an idle pane that declared a known external wait
# reports `paused` distinctly, so a supervisor reading this sees a declared pause
# and its reason rather than a wedge-suspect idle.
map_log_state() {  # <line>
  if status_is_paused "$1"; then
    echo paused
    return
  fi
  case "$(status_line_verb "$1")" in
    working)        echo working ;;
    needs-decision) echo parked ;;
    needs-review)   echo parked ;;
    blocked)        echo blocked ;;
    done)           echo "done" ;;
    failed)         echo failed ;;
    *)              echo unknown ;;
  esac
}

LOG_LINE=$(log_last_line || true)
LOG_VERB=$(status_line_verb "$LOG_LINE")

# pane_readable is consulted ONLY in the no-run fallback below. The run-step path
# stays authoritative regardless of pane liveness - judge by the run-step, not the
# shell - so a finished soldier whose pane has closed still reports its run-step
# state (e.g. done) instead of being masked as unknown.
PANE=$(cs_meta_get "$META" pane || true)
pane_readable() {  # <pane>
  cs_herdr_pane_exists "$1"
}
# crew_pane_is_busy: the busy-signature fallback. cs_herdr_agent_busy_state
# (bin/cs-herdr-lib.sh) is the one owner of the herdr status policy: native
# `working` is trusted outright as busy, while idle/unknown readings are
# corroborated against the rendered codex busy signature (CS_CODEX_BUSY_RE,
# "esc to interrupt") before the soldier may be read as not working. That
# corroboration matters here: herdr's agent.get reports generation state, which
# is a narrower signal than "this soldier's turn/tool call is still in
# progress". A soldier blocked on its own long-running foreground tool call
# (e.g. `no-mistakes axi run` without --yes, which blocks synchronously until a
# gate or outcome) is not generating for that whole span, so agent.get can read
# idle while the pane's own rendered text still shows the harness's busy banner
# for the entire tool call. Trusting a bare `idle` outright is what once let a
# still-working soldier read as not-busy - and, combined with a no-mistakes
# run-step lookup that also missed attribution (see nm_runs_status_for_branch) -
# as not provably working in cs-classify-lib.sh, triggering an immediate
# (non-wedge) stale wake instead of the absorb-then-escalate path. A genuinely
# human-blocked agent (a permission dialog, not mid-tool-call) does not render
# the busy banner, so the corroboration does not mask that case: it stays
# correctly not-busy.
crew_pane_is_busy() {  # <pane>
  [ "$(cs_herdr_agent_busy_state "$1" 2>/dev/null)" = busy ]
}

# --- no-mistakes run lookup (authoritative when a run matches this branch) --

# TOON parsing, the bounded no-mistakes call, and the run-attribution rules all
# live in bin/cs-nm-run-lib.sh so teardown and this reader share one owner (see
# that file's header). These thin wrappers keep the local call sites below
# reading against $RUN_OUT / $WT / $NM_TIMEOUT while the lib holds the logic.
RUN_OUT=""
trim() { cs_nm_trim "${1:-}"; }
strip_quotes() { cs_nm_strip_quotes "${1:-}"; }
nm_run() { cs_nm_run "$WT" "$NM_TIMEOUT" "$@"; }
nm_field() { cs_nm_field "$RUN_OUT" "$1"; }
nm_has_gate() { cs_nm_has_gate "$RUN_OUT"; }
nm_gate_line_name() { cs_nm_gate_line_name "$RUN_OUT"; }
nm_gate_name() { cs_nm_gate_name "$RUN_OUT"; }
nm_gate_findings_count() { cs_nm_gate_findings_count "$RUN_OUT"; }
log_reports_ci_ready() {
  [ "$LOG_VERB" = "done" ] || return 1
  case "$(status_line_note "$LOG_LINE")" in
    *PR*"checks green"*|*"checks green"*PR*) return 0 ;;
    *) return 1 ;;
  esac
}

nm_ci_step_status() {
  local row rest
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*ci,[[:space:]]*"?(running|fixing)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  rest=${row#*,}
  strip_quotes "$(trim "${rest%%,*}")"
}

nm_effective_ci_step_status() {
  local step_status
  if [ "${RUN_STATUS:-}" = fixing ]; then
    printf 'fixing'
    return 0
  fi
  step_status=$(nm_ci_step_status)
  if [ -n "$step_status" ]; then
    printf '%s' "$step_status"
    return 0
  fi
  if [ "${RUN_STATUS:-}" = ci ]; then
    printf 'running'
  fi
}

# Root cause of the PR #252 incident (2026-07): for a repo where merge is left
# to the boss, no-mistakes' ci step (and therefore top-level status/outcome)
# stays "running" for the ENTIRE CI-monitor phase, including long after GitHub
# reports every check green - it only reaches outcome=passed once the PR is
# actually merged (or failed/cancelled if closed). `axi status`'s steps[] table
# never distinguishes "still waiting on checks" from "checks green, waiting on
# merge": both read as plain `ci,running,...`. The only place that transition is
# recorded is the ci step's own log text, e.g. "all CI checks passed - still
# monitoring until merged or closed" or "no CI checks reported - still
# monitoring until merged or closed" (verified against 360+ real run logs under
# ~/.no-mistakes/logs/*/ci.log on the installed v1.32.2 binary, including the
# actual PR #252 run). Reads the ci step's log tail via `axi logs` and scans it
# for the MOST RECENT recognized marker (the log is append-only/chronological,
# so the last match is current): green with nothing red after it means CI is
# green right now, still only waiting on merge/close.
nm_ci_checks_state() {
  local run_id log_tail marker
  run_id=$(strip_quotes "$(nm_field id)")
  [ -n "$run_id" ] || { printf 'unknown'; return; }
  log_tail=$(nm_run axi logs --step ci --run "$run_id") || true
  [ -n "$log_tail" ] || { printf 'unknown'; return; }
  marker=$(printf '%s\n' "$log_tail" \
    | grep -E 'CI checks passed|no CI checks reported - still monitoring|no CI checks reported yet|checks failed|issues detected|CI checks running|base branch advanced.*re-arming CI monitor timeout' \
    | tail -1)
  case "$marker" in
    *"checks passed"*|*"no CI checks reported - still monitoring"*) printf 'green' ;;
    *"no CI checks reported yet"*|*"checks failed"*|*"issues detected"*|*"CI checks running"*|*"base branch advanced"*"re-arming CI monitor timeout"*) printf 'not-ready' ;;
    *) printf 'unknown' ;;
  esac
}
# Coarse fallback for cross-branch attribution. `no-mistakes axi status` (bare)
# reports the active-or-most-recent run for the CURRENT branch when one
# exists, else falls back to some other branch's run purely as informational
# display (verified empirically: querying a worktree with its own active run
# reliably returns that run, even under concurrent load from several other
# validating soldiers on the same underlying repo). A soldier whose branch
# genuinely has no run yet therefore sees another branch's answer here.
#
# This fallback used to shell out to `no-mistakes axi` (bare, no subcommand)
# expecting a `runs[N]{id,branch,status,...}:` TOON table and re-query the
# matched id via `axi status --run <id>`. Verified against the real installed
# CLI (v1.32.2): the `axi` surface exposes only abort/logs/respond/run/status -
# there is no runs-listing subcommand under `axi` at all, so that table never
# appears and the lookup was silently dead code; whenever the bare `axi
# status` answer was not this soldier's own branch, attribution always failed
# and the caller fell straight through to the pane/log fallback below. (The
# PRIMARY cause of the 2026-07 herdr false-surface incidents turned out to be
# a separate bug in the watcher's stale_is_terminal precedence - see the
# originating firstmate history - but this cross-branch path was independently
# confirmed dead code and is worth having actually work.)
#
# The real run-listing command is the top-level `no-mistakes runs`. The coarse
# cross-branch attribution (parse that plain text, match this branch's most
# recent row under the same head-identity rule as axi status) is owned by
# bin/cs-nm-run-lib.sh; this wrapper binds it to this reader's worktree and
# limit. See that file's header for the exact runs-list shape and rules.
nm_runs_status_for_branch() {  # <branch>
  cs_nm_runs_status_for_branch "$WT" "$1" "$CS_CREW_STATE_RUNS_LIMIT" "$NM_TIMEOUT"
}

# CREW_BRANCH is empty at detached HEAD (a just-spawned soldier, or a scout's
# scratch worktree); with no branch there is no run to attribute to this soldier.
CREW_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

# The head-identity rules (equal, or worktree HEAD is an ancestor of the run
# head; a strict-earlier, diverged, or unresolvable head is no match) are owned
# by cs_nm_head_matches_worktree. Branch match is the caller's precondition.
# This reader binds it to the axi-status TOON `head` field; the coarse runs-list
# form is applied inside cs_nm_runs_status_for_branch against the row's short-sha.
nm_run_head_matches_worktree() {
  cs_nm_head_matches_worktree "$WT" "$(strip_quotes "$(nm_field head)")"
}

HAVE_RUN=0
# RUN_SOURCE distinguishes the two ways HAVE_RUN=1 can happen: "full" means
# $RUN_OUT is real `axi status` TOON with step/gate detail; "coarse" means only
# a bare status word came back from the runs-list fallback above, so the
# run-step block below skips the TOON field parsing entirely for this soldier.
RUN_SOURCE=full
COARSE_STATUS=""
# Scouts and capos never drive a no-mistakes validation of their own
# worktree, so skip the lookup for them and read state from pane/log directly.
if [ "$KIND" = ship ] && [ -n "$CREW_BRANCH" ] && command -v no-mistakes >/dev/null 2>&1; then
  RUN_OUT=$(nm_run axi status)
  if [ -n "$RUN_OUT" ]; then
    run_branch=$(strip_quotes "$(nm_field branch)")
    if [ -n "$run_branch" ] && [ "$run_branch" = "$CREW_BRANCH" ] && nm_run_head_matches_worktree; then
      HAVE_RUN=1
    else
      # The active-or-most-recent run is for another branch, or same branch with
      # a rewritten/diverged head (the CLI is alive and answered; only the
      # attribution missed) - try the coarse fallback.
      # Deliberately nested inside `[ -n "$RUN_OUT" ]`: an empty/timed-out
      # primary call means the CLI itself did not respond, so retrying it
      # immediately with a second bounded call would just double the wait
      # for no better answer.
      COARSE_STATUS=$(nm_runs_status_for_branch "$CREW_BRANCH")
      if [ -n "$COARSE_STATUS" ]; then
        HAVE_RUN=1
        RUN_SOURCE=coarse
      fi
    fi
  fi
fi

# --- run-step authoritative path -------------------------------------------

if [ "$HAVE_RUN" = 1 ]; then
  RUN_STATE=working
  RUN_DETAIL=""
  CI_STEP_STATUS=""
  CI_LOG_STATE=""
  RUN_STATUS=""
  if [ "$RUN_SOURCE" = coarse ]; then
    # No step/gate detail is available from the plain runs list - only ever
    # true/working, done, or failed. A soldier genuinely parked at a gate still
    # gets full detail once `axi status` reports its own branch again (e.g.
    # once its own step is the most-recently-touched one), and its own
    # needs-decision/blocked status-log append (a boss-relevant VERB) is
    # surfaced through signal_reason_is_actionable regardless of this
    # coarse-vs-full distinction, so a real gate is never silently missed.
    case "$COARSE_STATUS" in
      running)   RUN_STATE=working; RUN_DETAIL="validating (background run)" ;;
      completed) RUN_STATE="done";  RUN_DETAIL="run completed" ;;
      failed)    RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
      cancelled) RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
      *)         RUN_STATE=unknown; RUN_DETAIL="runs list status: $COARSE_STATUS" ;;
    esac
  else
    status=$(strip_quotes "$(nm_field status)")
    RUN_STATUS=$status
    outcome=$(strip_quotes "$(nm_field outcome)")
    has_gate=0
    nm_has_gate && has_gate=1

    if [ -n "$outcome" ]; then
      case "$outcome" in
        passed)        RUN_STATE="done"; RUN_DETAIL="run passed: PR merged/closed" ;;
        checks-passed) RUN_STATE="done"; RUN_DETAIL="checks green: PR ready for review" ;;
        failed)        RUN_STATE=failed; RUN_DETAIL="run failed" ;;
        cancelled)     RUN_STATE=failed; RUN_DETAIL="run cancelled" ;;
        *)             RUN_STATE=unknown; RUN_DETAIL="outcome: $outcome" ;;
      esac
    elif cs_nm_run_is_gate_parked "$RUN_OUT"; then
      if [ "$has_gate" = 1 ]; then
        gate=$(nm_gate_line_name)
      else
        gate=$(nm_gate_name)
      fi
      [ -n "$gate" ] || gate=$status
      [ -n "$gate" ] || gate=gate
      RUN_STATE=parked
      RUN_DETAIL="parked at $gate"
      fcount=$(nm_gate_findings_count)
      [ -n "$fcount" ] && RUN_DETAIL="$RUN_DETAIL: $fcount finding(s)"
      if printf '%s\n' "$RUN_OUT" | grep -q 'ask-user'; then
        RUN_DETAIL="$RUN_DETAIL (ask-user: boss decision)"
      fi
    else
      case "$status" in
        ci)             RUN_STATE=working; RUN_DETAIL="ci running" ;;
        running|fixing) RUN_STATE=working; RUN_DETAIL="validating ($status)" ;;
        completed)      RUN_STATE="done"; RUN_DETAIL="run completed" ;;
        failed)         RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
        cancelled)      RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
        "")             RUN_STATE=working; RUN_DETAIL="run active" ;;
        *)              RUN_STATE=working; RUN_DETAIL="run active ($status)" ;;
      esac
      if [ "$RUN_STATE" = working ]; then
        CI_STEP_STATUS=$(nm_effective_ci_step_status)
        case "$CI_STEP_STATUS" in
          running)
            CI_LOG_STATE=$(nm_ci_checks_state)
            if [ "$CI_LOG_STATE" = green ]; then
              RUN_STATE="done"
              RUN_DETAIL="checks green: PR ready for review (still monitoring for merge/close)"
            fi
            ;;
          fixing)
            CI_LOG_STATE=not-ready
            ;;
        esac
      fi
    fi
  fi

  if [ "$RUN_STATE" = working ] && log_reports_ci_ready; then
    if [ "$RUN_SOURCE" = coarse ]; then
      emit "done" status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
    fi
    [ -n "$CI_STEP_STATUS" ] || CI_STEP_STATUS=$(nm_effective_ci_step_status)
    if [ "$RUN_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    elif [ "$CI_STEP_STATUS" = running ] && [ -z "$CI_LOG_STATE" ]; then
      CI_LOG_STATE=$(nm_ci_checks_state)
    elif [ "$CI_STEP_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    fi
    if [ "$CI_LOG_STATE" != not-ready ]; then
      emit "done" status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
    fi
  fi

  # Reconcile the status log. A needs-decision/needs-review/blocked log line
  # that the run-step has moved past (anything but a genuinely parked run) is
  # deterministically stale: the gate resolved and the run resumed or finished.
  # needs-review belongs here for the same reason - once a run exists for this
  # soldier, the review it was waiting on has already been acted on.
  case "$LOG_VERB" in
    needs-review)
      # Any attributed validation run proves the pre-validation review was
      # acted on. The run may itself be parked at a later gate, but the earlier
      # review request is still superseded.
      RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded (validation run exists)"
      ;;
    needs-decision|blocked)
      if [ "$RUN_STATE" != parked ]; then
        if [ "$RUN_STATE" = working ]; then
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded by active run"
        else
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded (run $RUN_STATE)"
        fi
      fi
      ;;
  esac

  emit "$RUN_STATE" run-step "$RUN_DETAIL"
fi

# --- fallback: no run attributed to this soldier ----------------------------
# The run-step path above already handled any soldier with a run, regardless of
# pane liveness, so a finished-but-pane-closed soldier never reaches here. Down
# here there is no run to consult, so a dead/unreadable pane means the soldier
# is gone: report unknown rather than trusting a possibly-stale status log as
# the current state.
[ -n "$PANE" ] || emit unknown none "no pane recorded"
pane_readable "$PANE" || emit unknown none "pane gone: $PANE"

# Capos idle on their own watcher (idle pane = healthy), so the busy signature
# is not meaningful for them; read their state from the status log only.
if [ "$KIND" != capo ] && crew_pane_is_busy "$PANE"; then
  emit working pane "harness busy"
fi

# Fall back to the status log's last line, but ONLY when its verb maps to a real
# run-state. A decision-closing event - resolved: (cs-classify-lib.sh's
# CS_CLASSIFY_RESOLVE_VERB), and any future decision-only sibling - is NOT a state:
# it exists solely to CLOSE a keyed decision in the durable fold, so a trailing
# resolved: must never become the current state or leak its resolution prose as the
# detail. Skipping it lets a just-resolved idle soldier (typically a capo, which
# has no busy check above) fall through to the idle default instead of rendering
# `unknown` with the resolution note as `doing`. map_log_state is the single owner of
# the verb->state mapping (including the configurable paused verb), so reusing its
# `unknown` verdict as the "not a state" test needs no second verb list here.
if [ -n "$LOG_VERB" ]; then
  LOG_STATE=$(map_log_state "$LOG_LINE")
  if [ "$LOG_STATE" != unknown ]; then
    emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")"
  fi
fi

# Last resort before giving up: ask what is actually RUNNING in the pane. A pane
# that survives its agent reads idle-or-unknown through `agent get`, which is
# indistinguishable by status alone from an agent between turns - and every
# source above has already declined, so there is nothing to lose by looking.
# Placed here deliberately, AFTER the status log: a soldier that finished and
# then exited must still report `done` from its log, not be relabelled a husk.
if cs_herdr_pane_is_agent_husk "$PANE"; then
  emit unknown pane-process "agent process gone; pane $PANE survives as a husk"
fi

emit unknown none "no current-state source available"
