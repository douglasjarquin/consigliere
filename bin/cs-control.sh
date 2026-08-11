#!/usr/bin/env bash
# Drive one direct report's AGENT LIFECYCLE with an allowlisted, verified verb.
#
# Usage: cs-control.sh interrupt <task-id>
#        cs-control.sh exit <task-id>
#        cs-control.sh relaunch <task-id> --note <text> [--model <name>] [--effort <level>] [--clear-journal]
#
# This is the control plane. bin/cs-send.sh is the data plane: conversational
# text for the agent to READ, routing-marked for a capo target. That marking is
# right for a message and wrong for a lifecycle command - a marked exit command
# arrives as ordinary chat the agent reasons about instead of executing - so
# lifecycle commands come through here, typed by nobody and allowlisted:
#
#   interrupt  cancel the running turn, leave the agent running
#   exit       stop the agent, preserve the pane, the worktree, and every
#              uncommitted change
#   relaunch   replace the running agent with a new one in the same pane and
#              worktree, as a journalled transaction
#
# There is no arbitrary-text and no raw-key entry point, and no verb ever
# removes a worktree, closes a pane, deletes a branch, or discards a change:
# bin/cs-teardown.sh owns destruction and its landed-work proofs.
#
# CS_HOME must be explicit (exported by the caller or set by the harness), the
# same fail-closed rule bin/cs-send.sh uses, so a lifecycle command can never
# resolve against another home's tasks.
#
# TARGETING IS EXACT. Only a bare task id with a state/<id>.meta record in this
# home is accepted; there is no pane-id form and no label search, because a
# "successful" lifecycle command against the wrong endpoint is worse than a loud
# refusal. A pane that herdr cannot positively confirm is refused too: "I could
# not reach herdr" is never read as an answer about the endpoint.
#
# REFUSED TARGETS
#   kind=capo    exit and relaunch. A capo is a persistent home with its own
#                state, backlog, and child tree; its lifecycle belongs to the
#                capo-provisioning skill. interrupt is allowed - cancelling a
#                turn changes nothing durable.
#   headless=1   every verb. A headless scout is a plain `codex exec`/`claude -p`
#                process with no composer to type into and no interactive agent
#                to resume; its turn end is process exit.
#
# EVERY ACTION VERIFIES ITS POSTCONDITION (bin/cs-control-lib.sh owns them):
#   interrupt  the turn is no longer running and the agent's PROCESS is still on
#              the pane - process evidence, not herdr's belief, because an exited
#              agent can leave a stale idle status behind. Already idle is
#              idempotent success only with that evidence. The interrupt key is
#              sent exactly once; an unconfirmed interrupt is reported, never
#              mashed.
#   exit       the pane is positively agent-free (its process table was read and
#              holds no agent process). Already gone is idempotent success.
#              Unsent text in the composer would be submitted together with the
#              exit command, so it is flushed first with one Enter and whatever
#              turn that starts is cancelled; docs/agent-control.md owns why that
#              is safer than refusing.
#   relaunch   an agent is alive on the recorded pane under a DIFFERENT process
#              than the one that was stopped. An unchanged agent session id is
#              proof of a failed COLD relaunch; on a resume the same id is
#              expected, because resuming continues the same session (verified in
#              docs/codex.md and docs/claude.md), which is why the process
#              identity is what decides.
# A verb that cannot prove its postcondition exits non-zero and reports the
# concrete observed state. It never reports success it did not verify.
#
# RELAUNCH IS A TRANSACTION with a durable journal at
# state/<id>.control-relaunch (flat key=value, last occurrence wins, read and
# written through bin/cs-meta-lib.sh):
#   phase=            prepared -> noted -> stopped -> launching -> done, or failed
#   started_utc=      when this transaction began
#   task= pane= worktree= project= kind= harness=
#   prior_model= prior_effort=   the recorded profile before this relaunch
#   model= effort=    the profile the replacement is launched on
#   head= dirty=      the work being preserved: HEAD and the uncommitted count
#   pre_pid= pre_session=        the agent that was running
#   stopped_pid=      the agent this transaction stopped
#   launch_path=      resume | cold
#   post_pid= post_session= post_state=  the agent that is running now, and the
#                     state it came up in (a replacement parked on a harness
#                     dialog is running and still needs a human)
#   note_utc=         when the progress note was appended to the brief
#   note_delivery=    steered | carried-in-the-brief | not-delivered
#   failed_phase= failed_reason= on a failure
#
# Ordering guarantees:
#   - Every refusal happens BEFORE the journal is written, the brief is touched,
#     or the agent is stopped, so a refused relaunch leaves this home's records
#     and the soldier's instructions byte-identical.
#   - The progress note is appended atomically (write, rename), so a failed
#     append cannot leave a half-written brief.
#   - A failure AFTER the stop reports the concrete state - which agent was
#     stopped, whether a replacement is running, where the work is preserved -
#     rather than claiming an agent that is not there.
#   - A journal left in a non-terminal phase means the process running the
#     transaction died mid-flight. The next relaunch REFUSES and prints that
#     state instead of launching a second agent; --clear-journal acknowledges it
#     (the stale journal is kept at state/<id>.control-relaunch.abandoned) and
#     starts a fresh transaction.
#
# --note is REQUIRED for a relaunch: the replacement inherits the local copy and
# none of the conversation. The note is appended to data/<id>/brief.md, so a
# cold launch reads it as part of its instructions and a later recovery still
# has it; on a resume it is also delivered as one steer through bin/cs-send.sh,
# because a resumed session does not re-read the brief.
#
# --model and --effort override the profile recorded in state/<id>.meta for this
# relaunch; bin/cs-spawn.sh --relaunch records the change once an agent is
# confirmed. The harness is NOT switchable here: a soldier inherits the root
# session's harness (AGENTS.md section 4), so moving one soldier alone would
# break that inheritance.
#
# Exit status: 0 verified success; 1 refusal or unverified postcondition;
# 2 usage error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage_die() { printf 'error: %s\n' "$*" >&2; printf 'run cs-control.sh --help for the verb list\n' >&2; exit 2; }

if [ -z "${CS_HOME+x}" ] || [ -z "${CS_HOME:-}" ]; then
  echo "error: CS_HOME is not set; cs-control refuses to resolve a lifecycle target without an explicit consigliere home" >&2
  exit 1
fi

# shellcheck source=bin/cs-herdr-lib.sh
. "$SCRIPT_DIR/cs-herdr-lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$SCRIPT_DIR/cs-meta-lib.sh"
# shellcheck source=bin/cs-harness-lib.sh
. "$SCRIPT_DIR/cs-harness-lib.sh"
# shellcheck source=bin/cs-composer-lib.sh
. "$SCRIPT_DIR/cs-composer-lib.sh"
# shellcheck source=bin/cs-control-lib.sh
. "$SCRIPT_DIR/cs-control-lib.sh"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root

VERB=${1:-}
[ -n "$VERB" ] || usage_die "a verb is required ($CS_CONTROL_VERBS)"
shift
cs_control_verb_valid "$VERB" || usage_die "'$VERB' is not a lifecycle verb ($CS_CONTROL_VERBS)"

ID=${1:-}
[ -n "$ID" ] || usage_die "$VERB requires a task id"
shift
case "$ID" in
  -*) usage_die "$VERB requires a task id, got the flag '$ID'" ;;
  w*[0-9]:p*[0-9]) usage_die "'$ID' is a pane id; cs-control targets a recorded task id only, so a lifecycle command can never land on an endpoint nobody recorded" ;;
  *[!A-Za-z0-9._-]*) usage_die "task id must be [A-Za-z0-9._-]+: '$ID'" ;;
esac

NOTE=
MODEL=
EFFORT=
CLEAR_JOURNAL=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --note) NOTE=${2:?--note requires a value}; shift 2 ;;
    --model) MODEL=${2:?--model requires a value}; shift 2 ;;
    --effort) EFFORT=${2:?--effort requires a value}; shift 2 ;;
    --clear-journal) CLEAR_JOURNAL=1; shift ;;
    *) usage_die "unknown argument '$1'" ;;
  esac
done
if [ "$VERB" != relaunch ]; then
  [ -z "$NOTE" ] || usage_die "--note applies only to relaunch"
  [ -z "$MODEL" ] || usage_die "--model applies only to relaunch"
  [ -z "$EFFORT" ] || usage_die "--effort applies only to relaunch"
  [ "$CLEAR_JOURNAL" -eq 0 ] || usage_die "--clear-journal applies only to relaunch"
fi

# --- resolve the target ------------------------------------------------------

META="$STATE/$ID.meta"
[ -f "$META" ] || die "no task '$ID' in this home (missing $META); cs-control targets an exact recorded direct report"
PANE=$(cs_meta_get "$META" pane) || die "no pane recorded in $META"
KIND=$(cs_meta_get "$META" kind 2>/dev/null || true)
[ -n "$KIND" ] || KIND=ship
HEADLESS=$(cs_meta_get "$META" headless 2>/dev/null || true)
WT=$(cs_meta_get "$META" worktree 2>/dev/null || true)
PROJECT=$(cs_meta_get "$META" project 2>/dev/null || true)
# A meta with no harness= predates the two-harness layer; codex was the only
# harness then, and bin/cs-send.sh reads such a record the same way.
HARNESS=$(cs_meta_get "$META" harness 2>/dev/null || true)
[ -n "$HARNESS" ] || HARNESS=codex
cs_harness_valid "$HARNESS" || die "task '$ID' records an unsupported harness '$HARNESS'"

if [ "$HEADLESS" = 1 ]; then
  die "task '$ID' is a headless scout: it has no composer to type into and no interactive agent to stop or resume. Its turn end is process exit; let it finish or discard the task through bin/cs-teardown.sh"
fi
if [ "$KIND" = capo ] && [ "$VERB" != interrupt ]; then
  die "task '$ID' is a capo: $VERB on a persistent home belongs to the capo-provisioning skill, which owns its state, backlog, and child work. interrupt is the only lifecycle verb allowed here"
fi

PRESENCE=$(cs_herdr_pane_presence "$PANE")
case "$PRESENCE" in
  present) ;;
  dead) die "task '$ID' has no endpoint left: herdr confirms pane $PANE is gone. Recover the recorded worktree with the stuck-soldier-recovery playbook; cs-control never recreates an endpoint" ;;
  *) die "herdr could not confirm pane $PANE for task '$ID' (presence: $PRESENCE); refusing to act on an unconfirmed endpoint" ;;
esac

report() { printf '%s\n' "$*"; }

# --- interrupt ---------------------------------------------------------------

if [ "$VERB" = interrupt ]; then
  rc=0
  token=$(cs_control_interrupt "$PANE" "$HARNESS") || rc=$?
  composer=$(cs_composer_state "$PANE" 2>/dev/null) || composer=unknown
  case "$token" in
    stopped)      report "interrupt $ID: turn stopped, agent still running (pane $PANE, composer $composer)" ;;
    already-idle) report "interrupt $ID: no turn was running (pane $PANE, composer $composer)" ;;
    blocked)      report "interrupt $ID: NOT interrupted - the agent is waiting on a human (native blocked), not on a turn (pane $PANE)" ;;
    still-working) report "interrupt $ID: NOT confirmed - the interrupt key was delivered and the turn was still observed running after ${CS_CONTROL_INTERRUPT_WAIT_SECS}s (pane $PANE)" ;;
    agent-gone)   report "interrupt $ID: pane $PANE no longer holds an agent; there is no turn to stop and nothing there to steer - recover through the stuck-soldier-recovery playbook" ;;
    state-unknown) report "interrupt $ID: NOT confirmed - the agent's state on pane $PANE cannot be positively read; \"cannot tell\" is never reported as an idle, stopped, or running agent" ;;
    *)            report "interrupt $ID: NOT confirmed ($token, pane $PANE)" ;;
  esac
  exit "$rc"
fi

# --- exit --------------------------------------------------------------------

if [ "$VERB" = exit ]; then
  pre_pid=$(cs_control_agent_pid "$PANE" 2>/dev/null || true)
  rc=0
  tokens=$(cs_control_stop "$PANE" "$HARNESS") || rc=$?
  itok=${tokens%% *}
  etok=${tokens##* }
  case "$etok" in
    gone|already-gone)
      report "exit $ID: agent gone from pane $PANE (was pid ${pre_pid:-unknown}, interrupt $itok); worktree and every uncommitted change untouched at ${WT:-<none>}"
      ;;
    command-not-sent)
      report "exit $ID: NOT stopped - herdr refused to deliver the exit command to pane $PANE (interrupt $itok)"
      ;;
    blocked)
      report "exit $ID: NOT stopped - the agent is waiting on a human (native blocked), and a key or command delivered there would be read as an answer, so the exit command was withheld (pane $PANE, interrupt $itok)"
      ;;
    exit-not-attempted)
      case "$itok" in
        blocked)
          report "exit $ID: NOT stopped - the agent is waiting on a human (native blocked), and a keystroke would answer that dialog, so the exit command was withheld (pane $PANE)"
          ;;
        still-working)
          report "exit $ID: NOT stopped - the running turn could not be interrupted ($itok), and a composer command is only queued as input mid-turn (pane $PANE)"
          ;;
        state-unknown)
          report "exit $ID: NOT stopped - the agent's state on pane $PANE cannot be positively read (interrupt $itok), so the exit command was withheld; \"cannot tell\" is never treated as a stopped or running agent"
          ;;
        *)
          report "exit $ID: NOT stopped - the exit command was not attempted (interrupt $itok, pane $PANE)"
          ;;
      esac
      ;;
    *)
      report "exit $ID: NOT confirmed - pane $PANE could not be confirmed agent-free (a turn that would not cancel, an agent that stayed, or an unreadable process table; pid $(cs_control_agent_pid "$PANE" 2>/dev/null || echo unreadable), interrupt $itok, exit $etok)"
      ;;
  esac
  exit "$rc"
fi

# --- relaunch ----------------------------------------------------------------

[ -n "$NOTE" ] || usage_die "relaunch requires --note <text>: the replacement inherits the local copy but none of the conversation"
case "$NOTE" in
  *$'\n'*) usage_die "--note must be a single line; put longer instructions in the brief" ;;
esac
if [ -n "$MODEL" ]; then
  case "$MODEL" in
    default|*[!A-Za-z0-9._:-]*) usage_die "--model must be a plain model identifier, got '$MODEL'" ;;
  esac
fi
if [ -n "$EFFORT" ]; then
  cs_harness_effort_valid "$HARNESS" "$EFFORT" ||
    usage_die "'$EFFORT' is not a $HARNESS effort level (default|low|medium|high|xhigh|max, plus ultra on codex)"
fi

BRIEF="$DATA/$ID/brief.md"
[ -f "$BRIEF" ] || die "task '$ID' has no brief at $BRIEF; a relaunch needs it as the replacement's instructions"
[ -n "$WT" ] || die "task '$ID' records no worktree; reconcile it with the stuck-soldier-recovery playbook before relaunching"
[ -d "$WT" ] || die "task '$ID' records worktree $WT, which is gone. Recover it with 'herdr worktree open --path' before relaunching; cs-control never recreates a worktree"
WT_REAL=$(cd "$WT" && pwd -P) || die "cannot resolve the recorded worktree $WT"
WT_TOP=$(git -C "$WT_REAL" rev-parse --show-toplevel 2>/dev/null || true)
WT_TOP_REAL=$(cd "${WT_TOP:-/nonexistent}" 2>/dev/null && pwd -P) || WT_TOP_REAL=
[ -n "$WT_TOP_REAL" ] && [ "$WT_TOP_REAL" = "$WT_REAL" ] ||
  die "recorded worktree $WT_REAL is not its own git worktree root (git reports '${WT_TOP:-none}'); refusing to relaunch into it"
# The launch owner (bin/cs-spawn.sh --relaunch) refuses a pane whose shell is
# not sitting in the recorded worktree; checked here too, BEFORE the agent is
# stopped, so that drift is a byte-identical refusal instead of a post-stop
# failure with the agent already down.
cwd_rc=0
cs_control_pane_in_dir "$PANE" "$WT_REAL" || cwd_rc=$?
case "$cwd_rc" in
  0) ;;
  1) die "pane $PANE's shell is not in the recorded worktree $WT_REAL; a replacement launched there would run outside the copy holding the work. Reconcile the pane with the stuck-soldier-recovery playbook before relaunching" ;;
  *) die "herdr did not report a working directory for pane $PANE; refusing to relaunch into an unverified location" ;;
esac

PRIOR_MODEL=$(cs_meta_get "$META" model 2>/dev/null || true)
PRIOR_EFFORT=$(cs_meta_get "$META" effort 2>/dev/null || true)
[ -n "$PRIOR_MODEL" ] || PRIOR_MODEL=default
[ -n "$PRIOR_EFFORT" ] || PRIOR_EFFORT=default
LAUNCH_MODEL=${MODEL:-$PRIOR_MODEL}
LAUNCH_EFFORT=${EFFORT:-$PRIOR_EFFORT}
cs_harness_effort_valid "$HARNESS" "$LAUNCH_EFFORT" ||
  die "task '$ID' records effort '$LAUNCH_EFFORT', which $HARNESS does not accept; pass --effort to choose a usable level"
# Mirrors the launch owner's own permission-mode validation, like the effort and
# pane-cwd checks above: a malformed config/permission-mode.conf must refuse
# here, with the agent still running, not after bin/cs-spawn.sh has it stopped.
cs_harness_permission_mode "$HARNESS" >/dev/null ||
  die "config/permission-mode.conf is malformed (details above); fix it before relaunching - the launch owner would refuse it only after the agent was stopped"

# The journal check runs LAST among the refusals: acknowledging a stale journal
# with --clear-journal displaces a record, so nothing that can still refuse may
# come after it.
JOURNAL=$(cs_control_journal_path "$STATE" "$ID")
if [ -e "$JOURNAL" ]; then
  [ -f "$JOURNAL" ] || die "$JOURNAL is not an ordinary file; investigate before relaunching"
  prev_phase=$(cs_control_journal_phase "$JOURNAL" 2>/dev/null || true)
  if ! cs_control_journal_terminal "$prev_phase"; then
    if [ "$CLEAR_JOURNAL" -eq 0 ]; then
      echo "error: a previous relaunch of '$ID' stopped at phase '${prev_phase:-unreadable}' and never finished; refusing to launch a second agent over it." >&2
      echo "The record is at $JOURNAL:" >&2
      sed 's/^/  /' "$JOURNAL" >&2
      echo "Live state now: agent pid $(cs_control_agent_pid "$PANE" 2>/dev/null || echo none) on pane $PANE." >&2
      echo "Inspect it, then re-run with --clear-journal to acknowledge that record and start a fresh transaction." >&2
      exit 1
    fi
    mv "$JOURNAL" "$(cs_control_journal_abandoned_path "$STATE" "$ID")" ||
      die "could not set aside the unfinished journal $JOURNAL"
    echo "note: acknowledged an unfinished relaunch of '$ID' at phase '${prev_phase:-unreadable}'; it is kept at $(cs_control_journal_abandoned_path "$STATE" "$ID")" >&2
  elif [ "$prev_phase" = failed ]; then
    echo "note: the previous relaunch of '$ID' failed at phase '$(cs_meta_get "$JOURNAL" failed_phase 2>/dev/null || echo unknown)'; starting a fresh transaction" >&2
  fi
fi

# Everything below this line changes durable state. Every refusal is above it.
NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
HEAD=$(git -C "$WT_REAL" rev-parse HEAD 2>/dev/null || echo unknown)
DIRTY=$(git -C "$WT_REAL" status --porcelain 2>/dev/null | grep -c . || true)
[ -n "$DIRTY" ] || DIRTY=0
PRE_PID=$(cs_control_agent_pid "$PANE" 2>/dev/null || true)
PRE_SESSION=$(cs_herdr_agent_session_id "$PANE" 2>/dev/null || true)

journal_set() { cs_meta_set "$JOURNAL" "$1" "$2"; }
journal_fail() { # <phase> <reason>
  journal_set failed_phase "$1"
  journal_set failed_reason "$2"
  journal_set phase failed
}

cs_meta_write "$JOURNAL" \
  "phase=prepared" \
  "started_utc=$NOW" \
  "task=$ID" \
  "pane=$PANE" \
  "worktree=$WT_REAL" \
  "project=${PROJECT:-}" \
  "kind=$KIND" \
  "harness=$HARNESS" \
  "prior_model=$PRIOR_MODEL" \
  "prior_effort=$PRIOR_EFFORT" \
  "model=$LAUNCH_MODEL" \
  "effort=$LAUNCH_EFFORT" \
  "head=$HEAD" \
  "dirty=$DIRTY" \
  "pre_pid=${PRE_PID:-}" \
  "pre_session=${PRE_SESSION:-}"

# The note goes into the instructions atomically: a cold launch reads the brief,
# and a later recovery of a failed relaunch still finds the note.
NOTE_TMP="$BRIEF.control.$$"
{
  cat "$BRIEF"
  printf '\n## Progress note (relaunch %s)\n\n%s\n\n' "$NOW" "$NOTE"
  printf 'Your local copy carries the work already done: %s at commit %s with %s uncommitted file(s).\n' \
    "$WT_REAL" "$HEAD" "$DIRTY"
} > "$NOTE_TMP" 2>/dev/null || {
  rm -f "$NOTE_TMP"
  journal_fail noting "could not stage the progress note"
  die "could not write the progress note beside $BRIEF; the brief is unchanged and no agent was stopped"
}
mv "$NOTE_TMP" "$BRIEF" || {
  rm -f "$NOTE_TMP"
  journal_fail noting "could not install the progress note"
  die "could not install the progress note into $BRIEF; the brief is unchanged and no agent was stopped"
}
journal_set note_utc "$NOW"
journal_set phase noted

rc=0
tokens=$(cs_control_stop "$PANE" "$HARNESS") || rc=$?
if [ "$rc" -ne 0 ]; then
  journal_fail stopping "$tokens"
  itok=${tokens%% *}
  etok=${tokens##* }
  if [ "$itok" = blocked ] || [ "$etok" = blocked ]; then
    stop_reason="the agent is waiting on a human (native blocked), which no key may answer"
  else
    case "$itok" in
      still-working) stop_reason="the running turn could not be cancelled" ;;
      state-unknown) stop_reason="the agent's state cannot be positively read" ;;
      *)             stop_reason="the agent could not be confirmed stopped" ;;
    esac
  fi
  echo "error: relaunch $ID: $stop_reason (interrupt $itok, exit $etok); NOTHING was relaunched." >&2
  echo "No stop was confirmed on pane $PANE, the work is untouched at $WT_REAL, and the progress note is in $BRIEF." >&2
  exit 1
fi
journal_set stopped_pid "${PRE_PID:-}"
journal_set phase stopped

journal_set phase launching
LAUNCH_ARGS=(--relaunch "$ID")
[ -n "$MODEL" ] && LAUNCH_ARGS+=(--model "$MODEL")
[ -n "$EFFORT" ] && LAUNCH_ARGS+=(--effort "$EFFORT")
spawn_rc=0
spawn_out=$("$SCRIPT_DIR/cs-spawn.sh" "${LAUNCH_ARGS[@]}" 2>&1) || spawn_rc=$?
if [ "$spawn_rc" -ne 0 ]; then
  journal_fail launching "cs-spawn --relaunch exited $spawn_rc"
  echo "error: relaunch $ID: the previous agent was stopped (pid ${PRE_PID:-unknown}) and the replacement did NOT come up." >&2
  printf '%s\n' "$spawn_out" >&2
  echo "No replacement agent was confirmed on pane $PANE. The work is preserved at $WT_REAL (commit $HEAD, $DIRTY uncommitted file(s)) and the progress note is in $BRIEF." >&2
  exit 1
fi
printf '%s\n' "$spawn_out" >&2

# The launch owner reports which path it took as `path=resume|cold`. Guessing it
# would be worse than refusing: the path decides whether the note still has to be
# steered in and whether an unchanged agent session id is evidence at all.
LAUNCH_PATH=$(printf '%s\n' "$spawn_out" | sed -n 's/.*[[:space:]]path=\([a-z]*\).*/\1/p' | tail -1)
case "$LAUNCH_PATH" in
  resume|cold) ;;
  *)
    journal_fail verifying "the launch owner did not report which launch path it took"
    echo "error: relaunch $ID: the launch reported success without naming its launch path, so nothing here can tell a resumed session from a cold one. Inspect pane $PANE before touching this task again." >&2
    exit 1
    ;;
esac
journal_set launch_path "$LAUNCH_PATH"

POST_PID=$(cs_control_agent_pid "$PANE" 2>/dev/null || true)
POST_SESSION=$(cs_herdr_agent_session_id "$PANE" 2>/dev/null || true)
# The replacement's observed state is reported rather than assumed healthy: a
# fresh agent can come up parked on a harness dialog (docs/codex.md), which is a
# live agent and still needs a human.
POST_STATE=$(cs_herdr_agent_busy_state "$PANE" 2>/dev/null) || POST_STATE=unknown
journal_set post_pid "${POST_PID:-}"
journal_set post_session "${POST_SESSION:-}"
journal_set post_state "$POST_STATE"

if [ -z "$POST_PID" ]; then
  journal_fail verifying "no agent process on the pane after the launch reported success"
  echo "error: relaunch $ID: the launch reported success but no agent process can be read on pane $PANE; treat the task as having no agent." >&2
  echo "The work is preserved at $WT_REAL (commit $HEAD, $DIRTY uncommitted file(s))." >&2
  exit 1
fi
if [ -n "$PRE_PID" ] && [ "$POST_PID" = "$PRE_PID" ]; then
  journal_fail verifying "pane still holds the original agent process $PRE_PID"
  echo "error: relaunch $ID: pane $PANE still holds the ORIGINAL agent process ($PRE_PID), so the relaunch did not happen whatever the launch reported." >&2
  exit 1
fi
# A cold launch starts a new session, so an unchanged session id would mean the
# original instance never left. A resume continues the same session by design,
# so the same id there is expected and proves nothing either way.
if [ "$LAUNCH_PATH" = cold ] && [ -n "$PRE_SESSION" ] && [ "$POST_SESSION" = "$PRE_SESSION" ]; then
  journal_fail verifying "cold relaunch kept agent session $PRE_SESSION"
  echo "error: relaunch $ID: the cold relaunch reports the same agent session id ($PRE_SESSION), so the original instance is still the one in pane $PANE." >&2
  exit 1
fi

NOTE_DELIVERY=carried-in-the-brief
if [ "$LAUNCH_PATH" = resume ]; then
  # A resumed session does not re-read the brief, so the note is steered in.
  if CS_HOME="$CS_HOME" "$SCRIPT_DIR/cs-send.sh" "$ID" "$NOTE" >/dev/null 2>&1; then
    NOTE_DELIVERY=steered
  else
    NOTE_DELIVERY=not-delivered
  fi
fi
journal_set note_delivery "$NOTE_DELIVERY"
journal_set phase 'done'

report "relaunch $ID: agent replaced via $LAUNCH_PATH on pane $PANE (pid ${PRE_PID:-unknown} -> $POST_PID, state $POST_STATE, $HARNESS model $LAUNCH_MODEL effort $LAUNCH_EFFORT); work preserved at $WT_REAL (commit $HEAD, $DIRTY uncommitted file(s)); progress note $NOTE_DELIVERY"
if [ "$POST_STATE" = blocked ]; then
  echo "warn: the replacement came up waiting on a human (native blocked) - it is running but will not work until that is answered; inspect pane $PANE" >&2
fi
if [ "$NOTE_DELIVERY" = not-delivered ]; then
  echo "warn: the replacement is running but the progress note could not be steered into it; it is in $BRIEF and can be sent with bin/cs-send.sh" >&2
  exit 1
fi
exit 0
