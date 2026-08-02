#!/usr/bin/env bash
# Shared wake classifier: the common source of truth for boss-relevant status
# tests, declared-external-wait vocabulary, and the working/paused absorb
# classification that makes no-verb signal and stale-pane wakes safe to absorb.
# Sourced by BOTH the always-on watcher (bin/cs-watch.sh) and the away-mode
# daemon (bin/cs-daemon.sh) so the overlapping triage policy lives in one place
# instead of two copies that can drift apart.
#
# Most functions are pure, side-effect-free reads of status files: each takes
# what it needs as arguments and touches no globals beyond the optional
# CS_BOSS_RE override. Consumers layer their own dedup/marker state on top.
#
# The one exception is the absorb classification (crew_absorb_class and its
# working/paused wrappers). It is NOT a pure status-file read: it reuses
# bin/cs-crew-state.sh, which may make a bounded no-mistakes call, to decide
# whether a soldier that just stopped its turn or went stale is working,
# deliberately paused, or neither. Callers run it ONLY on no-verb signal
# handling and first sighting of a stale hash, never on every wake, so the
# per-wake triage stays cheap.

_CS_CLASSIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _CS_CLASSIFY_LIB_DIR="."

# Machine-generated session input is structurally typed by the canonical wire
# owner. Unmarked text classifies as boss input without prose inspection.
# shellcheck source=bin/cs-operational-input.sh
. "$_CS_CLASSIFY_LIB_DIR/cs-operational-input.sh"

cs_classify_input() {  # <message> -> current kind or boss
  cs_operational_input_classify "${1-}"
}

cs_input_is_boss() {  # <message>
  [ "$(cs_classify_input "${1-}")" = boss ]
}

# The soldier current-state reader used for the "provably working" decision.
# Overridable so tests can stub the run-step/pane verdict without a real
# worktree or no-mistakes install; absent, it points at the real sibling script.
CS_CREW_STATE_BIN="${CS_CREW_STATE_BIN:-$_CS_CLASSIFY_LIB_DIR/cs-crew-state.sh}"

# Boss-relevant status verbs. A status line carrying any of these is work
# consigliere must see. Lines without these verbs are no-verb signals: the
# watcher absorbs them only with positive provably-working evidence, while the
# daemon uses its away-mode classification. CS_BOSS_RE overrides the whole set;
# absent, this default applies.
#
# Free-text tokens (PR ready, checks green, ready in branch, merged) exist only
# for legacy lines that lack a standard terminal verb. status_is_boss_relevant
# is verb-aware: a nonterminal working: or paused: line never becomes
# boss-relevant merely because its prose contains one of those tokens.
CS_CLASSIFY_BOSS_RE_DEFAULT='done:|needs-decision:|needs-review:|blocked:|failed:|PR ready|checks green|ready in branch|merged'

# The deliberate-external-wait verb. A soldier (or consigliere steering it)
# appends "paused: <reason>" to declare it is intentionally idling on a KNOWN
# external dependency. Unlike `blocked:` (stuck, consigliere must help) an idle
# `paused:` pane is EXPECTED, so the stale path absorbs it instead of
# escalating a possible wedge. It is deliberately NOT in the boss-relevant set:
# a pause is a "stop wedge-nagging this idle pane" signal, not work to keep
# surfacing. This constant is the ONE definition of the verb; both consumers
# read it here (status_is_paused). CS_CLASSIFY_PAUSED_VERB overrides it.
CS_CLASSIFY_PAUSED_VERB_DEFAULT='paused'

# Bounded re-surface cadence for a declared pause or a dead-agent boss hold.
# Far longer than the wedge threshold (CS_STALE_ESCALATE_SECS, default 240s), it
# avoids nagging a deliberate wait while ensuring a forgotten hold cannot rot
# invisibly. One hour by default; both consumers read CS_PAUSE_RESURFACE_SECS
# with this default so the cadence has one owner.
# shellcheck disable=SC2034 # Read by the watcher and daemon, not this lib.
CS_PAUSE_RESURFACE_SECS_DEFAULT=3600

# The resolution verb and durable-backlog-transfer verb that CLOSE a keyed
# status decision opened by needs-decision, needs-review, or blocked. See
# status_open_decisions below for the status-fold contract. The transfer verb
# is written only after
# cs-decision-hold.sh has verified the corresponding boss-held backlog item.
CS_CLASSIFY_RESOLVE_VERB_DEFAULT='resolved'
CS_CLASSIFY_BOSS_HELD_VERB_DEFAULT='captain-held'

# Return the last non-blank line of a status file (empty if missing/blank).
last_status_line() {
  local f=$1
  [ -e "$f" ] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1
}

# The pre-validation review verb. A no-mistakes soldier appends
# "needs-review: <what it built>" when its implementation is committed and it
# is waiting for consigliere to review that commit and trigger validation.
# It exists because `done:` cannot carry that meaning: `done:` also marks the
# green-PR end state, so a lane awaiting review was indistinguishable from a
# finished one and a missed review looked exactly like completed work. That is
# how niceuptime-590 idled 56m on 2026-08-02 with its wake events delivered and
# its status reading complete. This verb is terminal, boss-relevant, and OPENS
# a keyed decision that only an explicit resolution closes, so skipping the
# review is visible instead of silent.
# The verb is a fixed literal in the cases below rather than an overridable
# constant: unlike the pause verb, nothing configures it, and a second spelling
# would let the brief and the classifier disagree about which lanes are open.

# 0 if the given (last) status line's leading verb is a real terminal boss verb
# (done, needs-decision, needs-review, blocked, failed). Free-text tokens alone
# never count here; callers that need legacy free-text matching use
# status_is_boss_relevant.
status_is_terminal_verb() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    done|needs-decision|needs-review|blocked|failed) return 0 ;;
    *) return 1 ;;
  esac
}

# 0 if the given (last) status line matches a boss-relevant verb.
# Verb-aware by default: terminal verbs always match; nonterminal progress
# verbs (working, resolved, captain-held) and paused never match from free-text
# prose; only lines without those leading verbs may still match free-text
# tokens for legacy bare lines such as "merged" or "PR ready".
status_is_boss_relevant() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  status_is_paused "$line" && return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    working|resolved|captain-held|"${CS_CLASSIFY_PAUSED_VERB:-$CS_CLASSIFY_PAUSED_VERB_DEFAULT}")
      return 1
      ;;
  esac
  if [ -z "${CS_BOSS_RE+x}" ]; then
    case "$verb" in
      done|needs-decision|needs-review|blocked|failed) return 0 ;;
    esac
  fi
  printf '%s' "$line" | grep -qiE "${CS_BOSS_RE:-$CS_CLASSIFY_BOSS_RE_DEFAULT}"
}

# 0 if a status line's leading verb is the pause verb (paused: <reason>). A
# pure read of the line itself. Matches only the verb before the first colon,
# so a reason mentioning "paused" elsewhere does not false-match.
status_is_paused() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${CS_CLASSIFY_PAUSED_VERB:-$CS_CLASSIFY_PAUSED_VERB_DEFAULT}" ]
}

# 0 if a status line declares either an external-wait pause or a verified
# boss-held transfer. Both declarations can intentionally leave an exited
# soldier's endpoint idle, so the watcher applies its bounded pause cadence
# when agent death confirms that no live decision gate is being silenced.
status_is_paused_or_boss_held() {  # <status-line>
  local line=$1 verb
  status_is_paused "$line" && return 0
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${CS_CLASSIFY_BOSS_HELD_VERB:-$CS_CLASSIFY_BOSS_HELD_VERB_DEFAULT}" ]
}

# --- durable keyed decisions ------------------------------------------------
#
# The status stream is an append-only EVENT log. Reading it last-event-wins
# cannot represent "an earlier decision is still open after a later, unrelated
# event": a subsequent done/paused/working line silently masks a still-open
# needs-decision. status_open_decisions is the ONE authoritative statement of
# the status-fold contract that fixes this - a needs-decision/needs-review/blocked
# line OPENS a keyed decision. An explicit resolution referencing that key
# closes it. A verified boss-held backlog transfer may close needs-decision or
# blocked, but never needs-review: the required pre-validation review cannot be
# transferred away. A later unrelated terminal line never clears an open boss
# decision.
#
# Decision key grammar (backward-compatible with the plain "<verb>: <note>"
# format): an OPTIONAL "[key=<slug>]" token sits between the verb and the colon,
#   needs-decision [key=api-shape]: <summary>
#   resolved       [key=api-shape]: <how it was decided>
# A line with no token uses the key "default", preserving one-open-decision-
# per-task behavior (a bare "resolved:" closes "default").
status_line_verb() {  # <status-line> -> leading verb word
  local v=${1%%:*}
  v=${v%%\[key=*}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}
status_line_note() {  # <status-line> -> text after the first colon, trimmed
  case "$1" in
    *:*) local n=${1#*:}; printf '%s' "${n#"${n%%[![:space:]]*}"}" ;;
    *) printf '%s' "$1" ;;
  esac
}
_cs_decision_key() {  # <status-line> -> key slug, or "default" when no token
  local prefix=${1%%:*} k
  case "$prefix" in
    *\[key=*\]*)
      k=${prefix#*\[key=}
      k=${k%%\]*}
      case "$k" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
        *) printf '%s' "$k" ;;
      esac
      ;;
    *) printf 'default' ;;
  esac
}
# Drop the record for <key> from a newline-terminated "<key>\t<verb>\t<note>"
# set. Portable (no associative arrays) so the fold runs on bash 3.2 as well.
_cs_decision_drop() {  # <open-set> <key>
  local set=$1 key=$2 line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$key"$'\t'*) : ;;
      *) out="${out}${line}"$'\n' ;;
    esac
  done <<EOF
$set
EOF
  printf '%s' "$out"
}
_cs_decision_verb() {  # <open-set> <key> -> verb, or empty when not open
  local set=$1 key=$2 line record_key record_verb
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS=$'\t' read -r record_key record_verb _ <<EOF
$line
EOF
    if [ "$record_key" = "$key" ]; then
      printf '%s' "$record_verb"
      return 0
    fi
  done <<EOF
$set
EOF
  return 1
}
# Fold the WHOLE status stream into the set of decisions still open. Prints one
# TAB-separated "<key>\t<verb>\t<summary>" line per still-open decision, in
# most-recently-opened-last order; prints nothing when none are open. Pure read
# of the file. This is the durable open-set the fleet snapshot and any
# point-in-time consumer must use instead of trusting the last status line.
status_open_decisions() {  # <status-file>
  local f=$1 line verb key note resolve held open='' stripped open_verb
  [ -f "$f" ] || return 0
  resolve=${CS_CLASSIFY_RESOLVE_VERB:-$CS_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${CS_CLASSIFY_BOSS_HELD_VERB:-$CS_CLASSIFY_BOSS_HELD_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_cs_decision_key "$line") || continue
    case "$verb" in
      needs-decision|needs-review|blocked)
        note=$(status_line_note "$line")
        open=$(_cs_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      "$resolve")
        open=$(_cs_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
      "$held")
        open_verb=$(_cs_decision_verb "$open" "$key") || open_verb=''
        if [ "$open_verb" != needs-review ]; then
          open=$(_cs_decision_drop "$open" "$key")
          [ -n "$open" ] && open="${open}"$'\n'
        fi
        ;;
    esac
  done < "$f"
  printf '%s' "$open"
}

# Fold material routed-work phases in the same keyed event stream.
# A working or declared-pause event opens or replaces one phase for its key.
# A later done, failed, needs-decision, blocked, or resolved event carrying
# that key closes the phase. A bare legacy event uses the default key.
# This fold is evidence about whether a parent event was explicitly superseded.
# It is never authoritative current soldier state, and consumers must not let
# an open phase outrank a structured home snapshot or cs-crew-state result.
_cs_status_open_activities_stream() {
  local line verb key note resolve held open='' stripped pause
  resolve=${CS_CLASSIFY_RESOLVE_VERB:-$CS_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${CS_CLASSIFY_BOSS_HELD_VERB:-$CS_CLASSIFY_BOSS_HELD_VERB_DEFAULT}
  pause=${CS_CLASSIFY_PAUSED_VERB:-$CS_CLASSIFY_PAUSED_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_cs_decision_key "$line") || continue
    case "$verb" in
      working|"$pause")
        note=$(status_line_note "$line")
        open=$(_cs_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      done|failed|needs-decision|needs-review|blocked|"$resolve"|"$held")
        open=$(_cs_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done
  printf '%s' "$open"
}

status_open_activities() {  # <status-file-or-dash>
  local f=$1
  if [ "$f" = - ]; then
    _cs_status_open_activities_stream
    return 0
  fi
  [ -f "$f" ] || return 0
  _cs_status_open_activities_stream < "$f"
}

# task id from a recorded pane target, mapped through metadata; falls back to
# stripping a "cs-" prefix from the last path-ish segment.
pane_to_task() {
  local p=$1 state=${2:-${STATE:-${CS_STATE_OVERRIDE:-}}} meta mp t
  if [ -n "$state" ]; then
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      mp=$(grep '^pane=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ "$mp" = "$p" ] || continue
      t=$(basename "$meta")
      t=${t%.meta}
      printf '%s' "$t"
      return 0
    done
  fi
  t="${p##*:}"; t="${t#cs-}"; printf '%s' "$t"
}

# 0 (actionable) if ANY status file listed in a "signal:" wake carries a
# boss-relevant last line; 1 otherwise. Pass the space-separated file list that
# follows the "signal:" prefix. Non-.status arguments (e.g. .turn-ended
# markers, which never carry a verb) are skipped. A 1 here is NOT "benign" on
# its own: a no-verb signal is only benign when the soldier is also provably
# working (signal_crew_provably_working below); otherwise it surfaces.
signal_reason_is_actionable() {  # <file> ...
  local f last
  for f in "$@"; do
    [ -e "$f" ] || continue
    case "$f" in *.status) ;; *) continue ;; esac
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    status_is_boss_relevant "$last" && return 0
  done
  return 1
}

# Classify WHY an idle/stale soldier MIGHT be safely absorbed instead of
# surfaced, from bin/cs-crew-state.sh's one authoritative current-state line
# ("state: <s> · source: <src> · <detail>"). Prints exactly one token:
#   working - an actively-running no-mistakes step (running/fixing/ci) or a
#             busy pane; the soldier is legitimately mid-work;
#   paused  - the authoritative current state is a declared external-wait
#             pause, which is EXPECTED to idle;
#   none    - neither, so the wake must surface.
# One cs-crew-state.sh read serves BOTH absorb reasons at once. Reading the
# state authoritatively (not the status log) is what keeps run-step precedence:
# a soldier that appended paused: but then STARTED a run reports working.
# NOT a pure read: cs-crew-state.sh may make a bounded no-mistakes call, so
# callers run it only on no-verb signal and first-sighting stale paths.
# CS_CREW_STATE_BIN lets tests stub the verdict.
crew_absorb_class() {  # <id>
  local id=$1 line state src
  [ -n "$id" ] || { printf 'none'; return; }
  line=$("$CS_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) printf 'none'; return ;; esac
  state=${line#state: }; state=${state%% *}
  if [ "$state" = paused ]; then printf 'paused'; return; fi
  if [ "$state" = working ]; then
    src=${line#*source: }; src=${src%% *}
    case "$src" in run-step|pane) printf 'working'; return ;; esac
  fi
  printf 'none'
}

# 0 if soldier <id> shows POSITIVE evidence it is still working. This is the
# "provably working" predicate at the heart of absorb-only-when-provably-
# working: a no-verb turn-end or stale wake is absorbed ONLY when this returns
# 0, and SURFACED otherwise (the soldier may be done, waiting on a decision, or
# wedged). For stale panes it is checked before trusting the status log so a
# pre-validation boss-relevant line does not override an active run.
crew_is_provably_working() {  # <id>
  [ "$(crew_absorb_class "$1")" = working ]
}

# 0 if soldier <id>'s authoritative current state is a declared external-wait
# pause. The stale path absorbs such a soldier (on a long re-surface cadence)
# instead of escalating a possible wedge.
crew_is_paused() {  # <id>
  [ "$(crew_absorb_class "$1")" = paused ]
}

# 0 (benign/absorb) if EVERY task referenced by a no-verb "signal:" wake is
# provably working; 1 (actionable/surface) if any is not, or no task can be
# resolved. Files are mapped to task ids by stripping the .status /
# .turn-ended suffix; a no-verb wake with nothing provably working must
# surface, so an empty/unresolvable list returns 1.
signal_crew_provably_working() {  # <file> ...
  local f base task seen=""
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.status)     task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *)            continue ;;
    esac
    [ -n "$task" ] || continue
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    crew_is_provably_working "$task" || return 1
  done
  [ -n "$seen" ] || return 1
  return 0
}

# 0 (terminal/actionable) if a stale pane's last status line is boss-relevant;
# 1 otherwise, including the no-status case. A 1 only means "non-terminal";
# the always-on watcher then applies crew_is_provably_working, while the
# away-mode daemon applies its persistence recheck.
stale_is_terminal() {  # <pane> <state>
  local pane=$1 state=$2 last
  last=$(last_status_line "$state/$(pane_to_task "$pane" "$state").status")
  [ -n "$last" ] && status_is_boss_relevant "$last"
}

# Print "<file>\t<task>\t<last-line>" for every state/*.status whose last line
# is boss-relevant. This is the cheap fleet-scan both supervisors run as a
# catch-all backstop for a boss-relevant status the per-wake path might miss.
# No dedup is applied here: each consumer dedupes against its own seen-state.
scan_boss_relevant_statuses() {  # <state>
  local state=$1 f last task
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    status_is_boss_relevant "$last" || continue
    task=$(basename "$f"); task="${task%.status}"
    printf '%s\t%s\t%s\n' "$f" "$task" "$last"
  done
  return 0
}
