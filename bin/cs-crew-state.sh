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
#      `made status --json` (bin/cs-made-run-lib.sh's bounded, JSON-only
#      call), falling back to the coarse `runs` listing when the direct
#      answer belongs to another branch. Both are documented FORWARD
#      REFERENCES against subcommands made's CLI does not implement yet - see
#      bin/cs-made-run-lib.sh's own header.
#      The run's `state` field is AUTHORITATIVE: queued/running -> working,
#      completed -> done, failed -> failed. EXCEPT: a non-empty
#      `pending_findings[]` (ask-user findings raised by a gate, e.g. Review or
#      Document) overrides a `running` state to parked with the findings count
#      and the raising stage in the detail; and the `ci` pipeline stage's own
#      per-stage `result` overrides a `running` state to done once it reads
#      "pass" - the pipeline itself stays open waiting on a human merge (the
#      plan's no-merge-authority rule), so a green PR is never silently read as
#      still-validating - the same ci-monitor-after-green behavior the prior
#      validation backend had, but read straight off a live per-stage field on
#      every call instead of scraping the ci stage's full log for text markers.
#      That full log still lands in made's evidence store for a human to
#      inspect after the fact, but this reader never parses it: made's
#      daemon-backed snapshot has no "insufficient data" state the way a log
#      tail could, so a `pending` ci stage is trusted outright and a stale
#      status-log claim of "checks green" is never allowed to override it.
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
# Schema note: `made status --json` (cmd/made/status.go) has no per-run head/
# commit field yet, so the DIRECT match below (RUN_SOURCE=full) attributes a
# run to this soldier by branch name alone. The coarse `runs`-listing fallback
# is the one place head-identity (a reused branch name whose tip was rewritten
# or has diverged) is still verified, via cs_made_head_matches_worktree in
# bin/cs-made-run-lib.sh against the listing's short-sha column. This is a
# narrower safety net on the direct path than the prior text-based status
# reader had, tracked as a follow-up for whenever made's status schema grows a
# head field.
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
# How many of the most recent `made runs` rows the cross-branch fallback
# (made_runs_status_for_branch, below) scans. Generous enough to still find a
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
# progress". A soldier blocked on its own long-running foreground validation
# call (made's pipeline blocks synchronously until a gate or outcome) is not
# generating for that whole span, so agent.get can read idle while the pane's
# own rendered text still shows the harness's busy banner for the entire tool
# call. Trusting a bare `idle` outright is what once let a still-working
# soldier read as not-busy - and, combined with a made run-step lookup that
# also missed attribution (see made_runs_status_for_branch) - as not provably
# working in cs-classify-lib.sh, triggering an immediate (non-wedge) stale
# wake instead of the absorb-then-escalate path. A genuinely human-blocked
# agent (a permission dialog, not mid-tool-call) does not render the busy
# banner, so the corroboration does not mask that case: it stays correctly
# not-busy.
crew_pane_is_busy() {  # <pane>
  [ "$(cs_herdr_agent_busy_state "$1" 2>/dev/null)" = busy ]
}

# --- made run lookup (authoritative when a run matches this branch) --------

# The bounded call plumbing and the run-attribution rules (branch/head
# matching, gate-parked predicate for the coarse listing) live in
# bin/cs-made-run-lib.sh so teardown and this reader share one owner (see that
# file's header). This thin wrapper keeps the local call sites below reading
# against $RUN_OUT / $WT / $NM_TIMEOUT while the lib holds the bounded-exec
# contract.
RUN_OUT=""
made_run() { cs_made_run "$WT" "$NM_TIMEOUT" "$@"; }

# $RUN_OUT is `made status --json`'s report: schema_version, run_id, repo,
# branch, state, queued_at, started_at, ended_at, error, stages[]{name,
# result}, pending_findings[]{stage,message}. These read it with jq and fail
# soft (empty result) on anything that is not a well-formed report, so a
# timed-out or malformed call degrades to "no run" rather than a jq error.
made_field() {  # <jq filter>
  printf '%s' "$RUN_OUT" | jq -r "$1 // empty" 2>/dev/null
}
made_state() { made_field '.state'; }
made_error() { made_field '.error'; }
# The result ("pass"/"fail"/"pending") of the named pipeline stage, or empty
# when the stage is absent from the report.
made_stage_result() {  # <stage-name>
  printf '%s' "$RUN_OUT" | jq -r --arg s "$1" \
    '((.stages // [])[] | select(.name == $s) | .result) // empty' 2>/dev/null
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
# "gate" name in the parked detail.
made_pending_findings_stage() {
  printf '%s' "$RUN_OUT" | jq -r '(.pending_findings // [])[0].stage // empty' 2>/dev/null
}

log_reports_ci_ready() {
  [ "$LOG_VERB" = "done" ] || return 1
  case "$(status_line_note "$LOG_LINE")" in
    *PR*"checks green"*|*"checks green"*PR*) return 0 ;;
    *) return 1 ;;
  esac
}

# Coarse fallback for cross-branch attribution. `made status --json` with no
# run-id resolves the daemon-wide most-recently-queued run (cmd/made/status.go
# resolveRun), the same "may answer another soldier's run" shape the prior
# validation backend's bare `axi status` had - a soldier whose branch genuinely
# has no run yet, or whose run is not the most recently queued one, sees
# another branch's answer here.
#
# The real run-listing surface (a plain, human-oriented "made runs" table -
# forward reference, see bin/cs-made-run-lib.sh's header) is owned by that
# library: parse that table, match this branch's most recent row under the
# same head-identity rule as the direct lookup. This wrapper binds it to this
# reader's worktree and limit.
made_runs_status_for_branch() {  # <branch>
  cs_made_runs_status_for_branch "$WT" "$1" "$CS_CREW_STATE_RUNS_LIMIT" "$NM_TIMEOUT"
}

# CREW_BRANCH is empty at detached HEAD (a just-spawned soldier, or a scout's
# scratch worktree); with no branch there is no run to attribute to this soldier.
CREW_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

HAVE_RUN=0
# RUN_SOURCE distinguishes the two ways HAVE_RUN=1 can happen: "full" means
# $RUN_OUT is a real `made status --json` report with stage/finding detail;
# "coarse" means only a bare status word came back from the runs-list fallback
# above, so the run-step block below skips the JSON field parsing entirely for
# this soldier.
RUN_SOURCE=full
COARSE_STATUS=""
# Scouts and capos never drive a made validation of their own worktree, so
# skip the lookup for them and read state from pane/log directly.
if [ "$KIND" = ship ] && [ -n "$CREW_BRANCH" ] && command -v made >/dev/null 2>&1; then
  RUN_OUT=$(made_run status --json)
  if [ -n "$RUN_OUT" ] && printf '%s' "$RUN_OUT" | jq -e . >/dev/null 2>&1; then
    run_branch=$(made_field '.branch')
    if [ -n "$run_branch" ] && [ "$run_branch" = "$CREW_BRANCH" ]; then
      HAVE_RUN=1
    else
      # The most-recently-queued run belongs to another branch (the CLI is
      # alive and answered; only the attribution missed) - try the coarse
      # fallback. Deliberately nested inside a well-formed $RUN_OUT: an
      # empty/timed-out/malformed primary call means the CLI itself did not
      # respond usably, so retrying it immediately with a second bounded call
      # would just double the wait for no better answer.
      COARSE_STATUS=$(made_runs_status_for_branch "$CREW_BRANCH")
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
  if [ "$RUN_SOURCE" = coarse ]; then
    # No stage/finding detail is available from the plain runs list - only ever
    # queued/running, completed, or failed/cancelled. A soldier genuinely
    # parked at a gate still gets full detail once `made status --json`
    # reports its own branch again (e.g. once its own run is the
    # most-recently-queued one), and its own needs-decision/blocked
    # status-log append (a boss-relevant VERB) is surfaced through
    # signal_reason_is_actionable regardless of this coarse-vs-full
    # distinction, so a real gate is never silently missed.
    case "$COARSE_STATUS" in
      running|queued) RUN_STATE=working; RUN_DETAIL="validating (background run)" ;;
      completed)      RUN_STATE="done";  RUN_DETAIL="run completed" ;;
      failed)         RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
      cancelled)      RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
      *)              RUN_STATE=unknown; RUN_DETAIL="runs list status: $COARSE_STATUS" ;;
    esac

    # The coarse listing carries no per-stage detail at all, so a status-log
    # claim of "checks green" cannot be corroborated against a live signal the
    # way the direct path corroborates it against the ci stage's own result -
    # it is the only signal available here, so it is trusted outright.
    if [ "$RUN_STATE" = working ] && log_reports_ci_ready; then
      emit "done" status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
    fi
  else
    state=$(made_state)
    findings_count=$(made_pending_findings_count)
    case "$findings_count" in ''|*[!0-9]*) findings_count=0 ;; esac

    case "$state" in
      completed)
        RUN_STATE="done"; RUN_DETAIL="run completed"
        ;;
      failed)
        RUN_STATE=failed
        err=$(made_error)
        failed_stage=$(made_first_failed_stage)
        if [ -n "$err" ]; then
          RUN_DETAIL="run failed: $err"
        elif [ -n "$failed_stage" ]; then
          RUN_DETAIL="run failed at $failed_stage"
        else
          RUN_DETAIL="run failed"
        fi
        ;;
      running|queued)
        if [ "$findings_count" -gt 0 ]; then
          gate=$(made_pending_findings_stage)
          [ -n "$gate" ] || gate=gate
          RUN_STATE=parked
          RUN_DETAIL="parked at $gate: $findings_count finding(s) (ask-user: boss decision)"
        elif [ "$(made_stage_result ci)" = pass ]; then
          # The ci stage itself is authoritative for "checks green", read
          # straight off the live snapshot: a `running` top-level state with a
          # passed ci stage means the pipeline is only waiting on a human
          # merge (see the header note), which reads as done here regardless
          # of whether the soldier's own status log already said so.
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
