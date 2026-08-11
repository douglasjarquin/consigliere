#!/usr/bin/env bash
# cs-vault-cascade.sh - the mechanical inputs a /vault sweep needs to reach the
# capo homes: enumerate every registered capo exactly once, report each home's
# own startup-memory budget accounting, and resolve how the sweep reaches it.
#
# WHY THIS EXISTS. A /vault in the primary home used to curate the primary home
# and stop there. Capo homes carry their own config/boss-shared.md and
# config/learnings.md, read them in full at every one of their own session
# starts, and were never swept by anything - so their memory drifts uncurated
# and their startup cost only ever grows. This is the enumeration and routing
# half of closing that; skills/vault owns the memory-lifecycle contract and
# every judgment call.
#
# WHAT IT NEVER DOES. It reports. It never writes a memory file, never sends
# anything to a capo, never curates, and never decides what an entry is worth.
# The route it resolves is an input to consigliere's sweep, not an action.
#
# ROUTES, one per home:
#   send       a live agent holds this home, so ASK it to run its own /vault -
#              the only way that home's uncaptured session knowledge reaches
#              disk. The printed command is the ordinary marked kind=capo
#              cs-send path, so the capo's reply returns through its status.
#   curate     no live agent holds this home, so the invoking consigliere
#              curates what is already on disk there, in place.
#   exception  this home could not be evaluated at all (missing, unmarked,
#              wedged, ambiguous, or a liveness probe that could not answer).
#              The sweep reports it and CONTINUES; an unevaluated home is never
#              silently reported as swept, and never guessed at.
#
# Liveness is proved, not assumed: the recorded pane must still exist, must
# still root at that capo home (herdr recycles pane ids, and asking a recycled
# pane to run /vault would drop the request into whatever now owns it), and must
# still hold an agent. A probe that ERRORS is an exception, never a "curate":
# curating in place behind a live capo's back is exactly what an inconclusive
# probe must not cause.
#
# Each per-home step runs in a bounded child of this script, so a wedged home -
# an unreachable herdr, a hung stat on a stale network mount - costs one bound
# and is reported as an exception rather than hanging the whole sweep.
#
# Budgets are PER HOME and PER FILE. Sizes are never summed across homes: one
# home's headroom must never excuse another's overflow.
#
# Usage:
#   cs-vault-cascade.sh              report every registered capo home
#   cs-vault-cascade.sh --help
#
# Env:
#   CS_STARTUP_MEMORY_MAX_BYTES       per-file startup-memory budget (default 8192,
#                                     the same budget the session-start digest applies)
#   CS_VAULT_CASCADE_STEP_TIMEOUT     per-home hard bound in seconds (default 20)
#   CS_VAULT_CASCADE_REGISTRY_BYTES   max bytes read from host/capos.md (default 65536)
#
# Exit status: 0 when the sweep ran, whatever each home reported; 1 when the
# sweep itself could not run (a capo registry that exists but cannot be read, or
# an invocation from a capo home).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/cs-vault-cascade.sh"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
# shellcheck source=bin/cs-capo-registry-lib.sh
. "$SCRIPT_DIR/cs-capo-registry-lib.sh"
# shellcheck source=bin/cs-timeout-lib.sh
. "$SCRIPT_DIR/cs-timeout-lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$SCRIPT_DIR/cs-meta-lib.sh"
# shellcheck source=bin/cs-herdr-lib.sh
. "$SCRIPT_DIR/cs-herdr-lib.sh"
# shellcheck source=bin/cs-harness-lib.sh
. "$SCRIPT_DIR/cs-harness-lib.sh"

REG="$HOST_DIR/capos.md"

BUDGET=${CS_STARTUP_MEMORY_MAX_BYTES:-8192}
case "$BUDGET" in ''|*[!0-9]*|0) BUDGET=8192 ;; esac
STEP_TIMEOUT=${CS_VAULT_CASCADE_STEP_TIMEOUT:-20}
case "$STEP_TIMEOUT" in ''|*[!0-9]*|0) STEP_TIMEOUT=20 ;; esac
REGISTRY_BYTES=${CS_VAULT_CASCADE_REGISTRY_BYTES:-65536}
case "$REGISTRY_BYTES" in ''|*[!0-9]*|0) REGISTRY_BYTES=65536 ;; esac

# The startup memory a capo home pays for at every one of its own session
# starts, and the cold tier skills/vault retires entries into. The archive is
# reported for orientation only: it is never injected into a session, so it is
# never judged against the startup-memory budget.
MEMORY_FILES='config/boss.md config/boss-shared.md config/learnings.md'
ARCHIVE_REL='config/memory-archive.md'

usage() {
  sed -n '2,56p' "$0" | sed 's/^# \{0,1\}//'
}

# --- one home, run bounded in a child of this script -------------------------

record() {  # <key> <value...>
  local key=$1
  shift
  printf '  %s: %s\n' "$key" "$*"
}

memory_line() {  # <home> <relative-path>
  local path="$1/$2" size
  if [ ! -e "$path" ]; then
    record memory "$2 absent"
    return 0
  fi
  if [ ! -f "$path" ] || [ ! -r "$path" ]; then
    record memory "$2 unreadable"
    return 0
  fi
  size=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) record memory "$2 unreadable"; return 0 ;; esac
  if [ "$size" -gt "$BUDGET" ]; then
    record memory "$2 $size/$BUDGET OVER"
  else
    record memory "$2 $size/$BUDGET under"
  fi
}

archive_line() {  # <home>
  local path="$1/$ARCHIVE_REL" size
  if [ ! -f "$path" ]; then
    record archive "$ARCHIVE_REL absent (cold tier; created on the first retirement)"
    return 0
  fi
  size=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) size=unknown ;; esac
  record archive "$ARCHIVE_REL $size bytes (cold tier; never startup memory)"
}

# Resolve the route for one home. The pane comes from THIS home's own
# direct-report record for that capo, because that record is what the marked
# cs-send path resolves; a pane found any other way is not the endpoint the
# send would reach.
resolve_route() {  # <id> <home-abs>
  local id=$1 home=$2
  local meta="$STATE/$id.meta"
  local kind pane meta_home meta_home_abs harness prefix pane_json pane_cwd agent

  if [ ! -f "$meta" ]; then
    record route curate
    record reason "no direct-report record for $id in this home, so there is no agent to ask"
    return 0
  fi
  kind=$(cs_meta_get "$meta" kind 2>/dev/null || true)
  if [ "$kind" != capo ]; then
    record route exception
    record reason "state/$id.meta records kind='${kind:-absent}', not capo; resolve the record before sweeping this home"
    return 0
  fi
  meta_home=$(cs_meta_get "$meta" home 2>/dev/null || true)
  if [ -n "$meta_home" ] && [ -d "$meta_home" ]; then
    meta_home_abs=$(cd "$meta_home" && pwd -P)
  else
    meta_home_abs=$meta_home
  fi
  if [ -n "$meta_home_abs" ] && [ "$meta_home_abs" != "$home" ]; then
    record route exception
    record reason "state/$id.meta points at $meta_home_abs but the registry says $home; resolve the disagreement before sweeping either"
    return 0
  fi
  pane=$(cs_meta_get "$meta" pane 2>/dev/null || true)
  if [ -z "$pane" ]; then
    record route curate
    record reason "no pane recorded for $id, so there is no agent to ask"
    return 0
  fi

  if ! command -v herdr >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    record route exception
    record reason "herdr and jq are required to prove whether an agent holds $pane; liveness is unknown"
    return 0
  fi
  # Classified from the structured response body, never from the exit status:
  # `pane get` answers "no such pane" and "I cannot reach the server" over the
  # same failure exit, and only the first is proof the pane is gone.
  case "$(cs_herdr_pane_presence "$pane")" in
    dead)
      record route curate
      record reason "recorded pane $pane no longer exists"
      return 0
      ;;
    present) ;;
    *)
      record route exception
      record reason "the pane probe for $pane could not answer, so whether an agent holds it is unknown"
      return 0
      ;;
  esac
  if ! pane_json=$(cs_herdr pane get "$pane" 2>/dev/null) || [ -z "$pane_json" ]; then
    record route exception
    record reason "pane $pane could not be re-read after the presence probe, so liveness is unknown"
    return 0
  fi
  pane_cwd=$(printf '%s' "$pane_json" | jq -r '.result.pane.cwd // empty' 2>/dev/null)
  if [ -z "$pane_cwd" ]; then
    record route exception
    record reason "pane $pane reported no readable cwd, so whether it still roots at this home cannot be proved"
    return 0
  fi
  # Resolve both sides the same way before comparing: a home reached through a
  # symlink, or spelled with a redundant slash, is the same home, and reporting
  # it as a recycled pane would send the sweep down the wrong route.
  [ ! -d "$pane_cwd" ] || pane_cwd=$(cd "$pane_cwd" && pwd -P)
  if [ "$pane_cwd" != "$home" ]; then
    record route curate
    record reason "pane $pane now roots at $pane_cwd, not this home; the recorded id was recycled"
    return 0
  fi
  if ! agent=$(cs_herdr agent get "$pane" 2>/dev/null); then
    record route exception
    record reason "the liveness probe for $pane failed, so whether an agent holds it is unknown"
    return 0
  fi
  agent=$(printf '%s' "$agent" | jq -r '.result.agent.agent // empty' 2>/dev/null)
  if [ -z "$agent" ]; then
    record route curate
    record reason "no agent in pane $pane"
    return 0
  fi

  harness=$(cs_meta_get "$meta" harness 2>/dev/null || true)
  cs_harness_valid "$harness" || harness=codex
  prefix=$(cs_harness_skill_prefix "$harness")
  record route send
  record reason "agent $harness holds $pane"
  record command "CS_HOME=\"$CS_HOME\" \"$SCRIPT_DIR/cs-send.sh\" $id '${prefix}vault sweep this home now and report what you filed'"
}

home_step() {  # <id> <home> - one capo, always exits 0; the parent owns the bound
  local id=$1 home=$2 home_abs marker rel
  record home "$home"
  if [ ! -d "$home" ]; then
    record route exception
    record reason "home directory is missing"
    return 0
  fi
  if [ ! -r "$home" ] || [ ! -x "$home" ]; then
    record route exception
    record reason "home directory is unreadable"
    return 0
  fi
  home_abs=$(cd "$home" && pwd -P)
  if [ ! -f "$home_abs/.cs-capo-home" ]; then
    record route exception
    record reason "not a marked capo home (.cs-capo-home missing)"
    return 0
  fi
  marker=$(tr -d '[:space:]' < "$home_abs/.cs-capo-home" 2>/dev/null)
  if [ "$marker" != "$id" ]; then
    record route exception
    record reason "home is marked for capo ${marker:-unknown}, not $id"
    return 0
  fi
  for rel in $MEMORY_FILES; do
    memory_line "$home_abs" "$rel"
  done
  archive_line "$home_abs"
  resolve_route "$id" "$home_abs"
}

# --- entry point -------------------------------------------------------------

case "${1:-}" in
  '') ;;
  -h|--help) usage; exit 0 ;;
  --home-step)
    # Internal: the bounded per-home child. Documented so a test (and a human
    # debugging one wedged home) can drive exactly one home.
    [ $# -eq 3 ] || { echo "usage: cs-vault-cascade.sh --home-step <id> <home>" >&2; exit 2; }
    home_step "$2" "$3"
    exit 0
    ;;
  *) echo "usage: cs-vault-cascade.sh [--help]" >&2; exit 2 ;;
esac

if [ -f "$CS_HOME/.cs-capo-home" ]; then
  echo "error: cs-vault-cascade runs in the primary home; $CS_HOME is a capo home. A capo's own /vault sweeps that home and stops - only the primary home cascades." >&2
  exit 1
fi

printf 'vault cascade from %s\n' "$CS_HOME"
printf 'budget: %s bytes per startup-memory file, applied to each home on its own; sizes are never summed across homes\n' "$BUDGET"
printf 'bound: %ss per home\n' "$STEP_TIMEOUT"

if ! cs_capo_registry_exists "$REG"; then
  printf 'capos: 0 registered (no %s)\n' "$REG"
  printf 'summary: 0 send, 0 curate, 0 exception\n'
  exit 0
fi
# Availability is checked HERE, in this shell, so its reason survives; the
# record capture below runs in a subshell that could not hand one back.
if ! cs_capo_registry_available "$REG"; then
  echo "error: $CS_CAPO_REGISTRY_ERROR" >&2
  echo "       the capo routing table could not be read, so this sweep cannot know which homes exist; it is NOT an empty fleet." >&2
  exit 1
fi
if ! RECORDS=$(cs_capo_registry_records "$REG" "$REGISTRY_BYTES"); then
  echo "error: capo registry could not be read: $REG" >&2
  exit 1
fi

TOTAL=0
[ -z "$RECORDS" ] || TOTAL=$(printf '%s\n' "$RECORDS" | wc -l | tr -d ' ')
printf 'capos: %s registered\n' "$TOTAL"

# CS_HOME may have been resolved from a default rather than the environment, and
# the bounded child resolves its own home from the environment alone.
export CS_HOME

# Newline-delimited, because a home path may legally contain a space and a
# space-delimited membership test would then match the wrong prefix.
NL='
'
SEEN_IDS=$NL
SEEN_HOMES=$NL
SENDS=0
CURATES=0
EXCEPTIONS=0

emit_exception() {  # <reason...>
  printf '  route: exception\n'
  printf '  reason: %s\n' "$*"
  EXCEPTIONS=$((EXCEPTIONS + 1))
}

if [ -n "$RECORDS" ]; then
  while IFS=$'\t' read -r status id home scope raw; do
    # scope rides the record stream but nothing here routes on it: which capo
    # owns which work is an intake question, and every registered home's memory
    # is swept regardless.
    : "$scope"
    if [ "$status" != ok ]; then
      printf '\ncapo: (unparsed)\n'
      emit_exception "malformed registry entry: $raw"
      continue
    fi
    # Exactly once, per the enumeration contract: a duplicated id or a second
    # row bound to the same home would otherwise be swept twice, which means
    # asking one capo twice or curating one home's memory twice in one pass.
    # A repeat row is headed distinctly, so a reader (and a counter) can tell a
    # sweep record from a refusal to sweep the same home again.
    case "$SEEN_IDS" in
      *"$NL$id$NL"*)
        printf '\ncapo: %s (repeat registry row)\n' "$id"
        emit_exception "capo $id has more than one registry entry; resolve the duplicate before sweeping it"
        continue
        ;;
    esac
    SEEN_IDS="$SEEN_IDS$id$NL"
    case "$SEEN_HOMES" in
      *"$NL$home$NL"*)
        printf '\ncapo: %s (repeat home)\n' "$id"
        emit_exception "home $home is already registered to another capo in this table; resolve the duplicate before sweeping it"
        continue
        ;;
    esac
    SEEN_HOMES="$SEEN_HOMES$home$NL"
    printf '\ncapo: %s\n' "$id"

    # stdin comes from the record heredoc this loop is reading; the bounded
    # child must never be handed it.
    OUT=$(cs_run_timed "$STEP_TIMEOUT" "$SELF" --home-step "$id" "$home" < /dev/null)
    RC=$?
    case "$RC" in
      0)
        printf '%s\n' "$OUT"
        case "$(printf '%s\n' "$OUT" | sed -n 's/^  route: //p' | head -1)" in
          send) SENDS=$((SENDS + 1)) ;;
          curate) CURATES=$((CURATES + 1)) ;;
          *) EXCEPTIONS=$((EXCEPTIONS + 1)) ;;
        esac
        ;;
      124)
        # Partial output from a killed step would read as a complete record, so
        # it is discarded rather than printed alongside the exception.
        printf '  home: %s\n' "$home"
        emit_exception "evaluating this home exceeded the ${STEP_TIMEOUT}s bound; it was not swept"
        ;;
      "$CS_TIMEOUT_UNAVAILABLE")
        printf '  home: %s\n' "$home"
        emit_exception "the per-home bound could not be established, so this home was never evaluated"
        ;;
      *)
        printf '  home: %s\n' "$home"
        emit_exception "evaluating this home failed (exit $RC); it was not swept"
        ;;
    esac
  done <<EOF
$RECORDS
EOF
fi

printf '\nsummary: %s send, %s curate, %s exception\n' "$SENDS" "$CURATES" "$EXCEPTIONS"
exit 0
