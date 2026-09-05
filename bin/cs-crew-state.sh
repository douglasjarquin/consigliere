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
# (a made pipeline run attributed to this soldier's branch and current code
# identity, else the pane busy-signature) and reconciles the possibly-stale log
# against it.
#
# The local reconciliation is deterministic - only run-step / pane / log reads
# plus fixed mapping logic, no heuristics and no LLM. The shared made run
# attribution and gate-parked predicates live in bin/cs-made-run-lib.sh, their
# one owner for this reader and teardown. Output is one stable, parseable,
# token-tight line consigliere can read every heartbeat:
#
#   state: <working|parked|done|blocked|paused|failed|unknown> · source: <run-step|pane|status-log|pane-process|none> · <detail>
#
# Logic, in order:
#   1. Resolve worktree + pane + kind from state/<id>.meta.
#   2. Resolve a made pipeline run for this soldier's branch through
#      `made run list --json` (bin/cs-made-run-lib.sh's cs_made_resolve_run),
#      which filters made's real run listing by branch and verifies head
#      identity (cs_made_head_matches_worktree) before ever returning a row -
#      a cross-branch run cannot be misattributed, unlike a bare status call.
#      The resolved row is always a full StatusReport (docs/made.md): there is
#      no separate "coarse" (headless) attribution path any more.
#      The run's `state` field is AUTHORITATIVE: queued/running -> working,
#      awaiting_review -> parked, awaiting_merge/succeeded -> done,
#      failed/canceled -> failed, superseded -> stale. EXCEPT: the `ci`
#      pipeline stage's own per-stage `result` overrides a `running` state to
#      done once it reads "pass" - the pipeline itself stays open waiting on a
#      human merge (the plan's no-merge-authority rule), so a green PR is
#      never silently read as still-validating. That full log still lands in
#      made's evidence store for a human to inspect after the fact, but this
#      reader never parses it: made's daemon-backed snapshot has no
#      "insufficient data" state the way a log tail could, so a `pending` ci
#      stage is trusted outright.
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
# Schema note: made's real `run list --json` rows carry both `branch` and a
# head (`output_sha`, falling back to `input_sha`) on every row, so head
# identity (a reused branch name whose tip was rewritten or has diverged) is
# verified on every lookup, not only a fallback path - see docs/made.md and
# bin/cs-made-run-lib.sh's header for the full verified command surface.
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
# shellcheck source=bin/cs-made-run-lib.sh
. "$SCRIPT_DIR/cs-made-run-lib.sh"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: cs-crew-state.sh <id>" >&2; exit 2; }

META="$STATE/$ID.meta"
LOG="$STATE/$ID.status"
NM_TIMEOUT=${CS_CREW_STATE_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac
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
# progress". A soldier blocked on its own long-running foreground validation
# call (made's pipeline blocks synchronously until a gate or outcome) is not
# generating for that whole span, so agent.get can read idle while the pane's
# own rendered text still shows the harness's busy banner for the entire tool
# call. Trusting a bare `idle` outright is what once let a still-working
# soldier read as not-busy - and, combined with a made run-step lookup that
# also missed attribution (see cs_made_resolve_run) - as not provably
# working in cs-classify-lib.sh, triggering an immediate (non-wedge) stale
# wake instead of the absorb-then-escalate path. A genuinely human-blocked
# agent (a permission dialog, not mid-tool-call) does not render the busy
# banner, so the corroboration does not mask that case: it stays correctly
# not-busy.
crew_pane_is_busy() {  # <pane>
  [ "$(cs_herdr_agent_busy_state "$1" 2>/dev/null)" = busy ]
}

# --- made run lookup (authoritative when a run matches this branch) --------

# Real attribution (branch + head match over made's real `run list --json`)
# lives in bin/cs-made-run-lib.sh so teardown and this reader share one
# owner (see that file's header). $RUN_OUT is always a full StatusReport
# JSON object when a run is found - made's real run-list rows carry full
# per-stage/pending-findings detail, so unlike the earlier text-based lookup
# this replaces, there is no separate "coarse" (headless) attribution path
# any more.
RUN_OUT=""
made_resolve_run() { cs_made_resolve_run "$WT" "$NM_TIMEOUT" "$1"; }

# $RUN_OUT fields used below: run_id, branch, state, execution_finished,
# pr_url, error, errors[], stages[]{name,result,message,error},
# pending_findings[]{stage,message}. jq reads fail soft (empty) on
# anything not well-formed, so a timed-out or malformed call degrades to
# "no run" rather than a jq error.
made_field() {  # <jq filter>
  printf '%s' "$RUN_OUT" | jq -r "$1 // empty" 2>/dev/null
}
made_state() { made_field '.state'; }
made_pr_url() { made_field '.pr_url'; }
made_top_error() { made_field '.error'; }
made_errors_joined() {
  printf '%s' "$RUN_OUT" | jq -r '(.errors // []) | join("; ")' 2>/dev/null
}
# The result ("pass"/"fail"/"skipped") of the named pipeline stage, or empty
# when the stage has not run yet (made only appends a stage once it runs).
made_stage_result() {  # <stage-name>
  printf '%s' "$RUN_OUT" | jq -r --arg s "$1" \
    '((.stages // [])[] | select(.name == $s) | .result) // empty' 2>/dev/null
}
made_stage_detail() {  # <stage-name> - that stage's own .message, else .error
  printf '%s' "$RUN_OUT" | jq -r --arg s "$1" \
    '((.stages // [])[] | select(.name == $s) | (.message // .error // "")) // empty' 2>/dev/null
}
# The first stage (in pipeline order) that has not passed - the pipeline's
# current position, for the "validating (<stage>)" detail. Empty once every
# stage has passed.
made_active_stage() {
  printf '%s' "$RUN_OUT" | jq -r \
    '((.stages // [])[] | select(.result != "pass") | .name)' 2>/dev/null | head -1
}
made_first_failed_stage() {
  printf '%s' "$RUN_OUT" | jq -r \
    '((.stages // [])[] | select(.result == "fail") | .name)' 2>/dev/null | head -1
}
made_pending_findings_count() {
  printf '%s' "$RUN_OUT" | jq -r '(.pending_findings // []) | length' 2>/dev/null
}
# The stage that raised the first pending ask-user finding - reported as the
# "gate" name in the parked detail. Only "review" and "document" ever
# populate this (docs/made.md).
made_pending_findings_stage() {
  printf '%s' "$RUN_OUT" | jq -r '(.pending_findings // [])[0].stage // empty' 2>/dev/null
}

# CREW_BRANCH is empty at detached HEAD (a just-spawned soldier, or a scout's
# scratch worktree); with no branch there is no run to attribute to this soldier.
CREW_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

HAVE_RUN=0
# Scouts and capos never drive a made validation of their own worktree, so
# skip the lookup for them and read state from pane/log directly.
if [ "$KIND" = ship ] && [ -n "$CREW_BRANCH" ] && command -v made >/dev/null 2>&1; then
  RUN_OUT=$(made_resolve_run "$CREW_BRANCH") || RUN_OUT=""
  if [ -n "$RUN_OUT" ] && printf '%s' "$RUN_OUT" | jq -e . >/dev/null 2>&1; then
    HAVE_RUN=1
  fi
fi

# --- run-step authoritative path -------------------------------------------

if [ "$HAVE_RUN" = 1 ]; then
  RUN_STATE=working
  RUN_DETAIL=""
  state=$(made_state)
  findings_count=$(made_pending_findings_count)
  case "$findings_count" in ''|*[!0-9]*) findings_count=0 ;; esac

  case "$state" in
    succeeded)
      RUN_STATE="done"; RUN_DETAIL="run completed"
      ;;
    awaiting_merge)
      pr=$(made_pr_url)
      if [ -n "$pr" ]; then
        RUN_STATE="done"; RUN_DETAIL="checks green: PR ready for review ($pr) - still monitoring for merge/close"
      else
        RUN_STATE="done"; RUN_DETAIL="checks green: PR ready for review - still monitoring for merge/close"
      fi
      ;;
    failed)
      RUN_STATE=failed
      err=$(made_top_error)
      [ -n "$err" ] || err=$(made_errors_joined)
      failed_stage=$(made_first_failed_stage)
      if [ -n "$err" ]; then
        RUN_DETAIL="run failed: $err"
      elif [ -n "$failed_stage" ]; then
        detail=$(made_stage_detail "$failed_stage")
        if [ -n "$detail" ]; then
          RUN_DETAIL="run failed at $failed_stage: $detail"
        else
          RUN_DETAIL="run failed at $failed_stage"
        fi
      else
        RUN_DETAIL="run failed"
      fi
      ;;
    canceled)
      RUN_STATE=failed; RUN_DETAIL="run cancelled"
      ;;
    superseded)
      RUN_STATE=stale; RUN_DETAIL="run superseded by a later push"
      ;;
    awaiting_review)
      gate=$(made_pending_findings_stage)
      [ -n "$gate" ] || gate=gate
      RUN_STATE=parked
      RUN_DETAIL="parked at $gate: $findings_count finding(s) (ask-user: boss decision)"
      ;;
    running|queued)
      if [ "$(made_stage_result ci)" = pass ]; then
        # The ci stage itself is authoritative for "checks green": a
        # `running` top-level state with a passed ci stage means the
        # pipeline is only waiting on later stages, which reads as done
        # here regardless of whether the soldier's own status log already
        # said so.
        RUN_STATE="done"
        RUN_DETAIL="checks green: PR ready for review (still monitoring for merge/close)"
      elif [ "$state" = queued ]; then
        RUN_STATE=working; RUN_DETAIL="run queued"
      else
        active=$(made_active_stage)
        if [ -n "$active" ]; then
          RUN_STATE=working; RUN_DETAIL="validating ($active)"
        else
          RUN_STATE=working; RUN_DETAIL="run active"
        fi
      fi
      ;;
    *)
      RUN_STATE=unknown; RUN_DETAIL="state: $state"
      ;;
  esac

  # Reconcile the status log. A needs-decision/needs-review/blocked log line
  # that the run-step has moved past (anything but a genuinely parked run) is
  # deterministically stale: the gate resolved and the run resumed or finished.
  case "$LOG_VERB" in
    needs-review)
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
