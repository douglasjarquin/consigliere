# shellcheck shell=bash
# cs-telemetry-lib.sh - the single owner of consigliere's optional turn telemetry.
#
# Telemetry answers ONE measurement question: what share of scarce frontier-model
# usage goes to root and capo supervision, and how much of that supervision ends
# in "still working, keep waiting" rather than in an action. It is measurement
# only. It never changes dispatch, wake classification, checkpoint behavior,
# monitoring, worker lifecycle, model or harness selection, prompts, delivery
# mode, merge or review behavior, or failure handling.
#
# This library owns EVERYTHING about that: enablement, config parsing, path
# resolution, the schema version, event ids, timestamps, the safe append, JSON
# serialization, breadcrumb recording and folding, harness usage extraction, and
# retention. Callers use a narrow API and never learn the file format, the path,
# or the schema:
#
#   cs_telemetry_crumb <kind> [detail]        record one turn-scoped breadcrumb
#   cs_telemetry_turn_end <role> [payload]    fold this turn's crumbs and emit
#   cs_telemetry_worker_turn_end <id> [pay]   emit one ship/scout worker turn
#   cs_telemetry_config_status                disabled|enabled <days>|malformed <why>
#
# docs/telemetry.md is the human-facing contract (what is and is not collected,
# how to enable, disable, report on, and delete it). docs/configuration.md owns
# the host/telemetry.conf row and the data/telemetry/ tier.
#
# FAILURE POLICY, the load-bearing rule: every public function swallows every
# failure and returns 0. An unwritable path, a malformed config, an unparseable
# usage payload, a missing jq, or any other telemetry error must leave the
# caller's exit status, stdout, stderr, and side effects exactly as they were
# without telemetry. Callers run under `set -e`; a non-zero return here would
# kill a spawn, a steer, or a merge, which is precisely the behavioral change
# this instrumentation must not cause. Nothing in this file writes to stdout or
# stderr except cs_telemetry_config_status, which exists for the doctor.
#
# Dependency honesty: serialization and usage extraction need `jq` (a REQUIRED
# consigliere dependency, bin/cs-deps-lib.sh). Without jq telemetry is a silent
# no-op, and bin/cs-doctor.sh reports it. Breadcrumbs are plain text and need
# nothing.
#
# Usage: . bin/cs-telemetry-lib.sh

# Idempotent guard: sourcing twice must not redefine or reset anything.
if [ -n "${CS_TELEMETRY_LIB_SOURCED:-}" ]; then
  return 0
fi
CS_TELEMETRY_LIB_SOURCED=1

# The record schema version. Bump ONLY on an incompatible change; every field
# except schema, timestamp, and event_id is nullable precisely so a new field is
# an addition rather than a new schema.
CS_TELEMETRY_SCHEMA=1

# Hard caps. A record longer than this is dropped rather than appended: a single
# write() below the platform pipe-buffer size is what keeps concurrent appends
# from interleaving, and the field set cannot legitimately approach it.
CS_TELEMETRY_MAX_RECORD_BYTES=${CS_TELEMETRY_MAX_RECORD_BYTES:-4000}
# Breadcrumbs are turn-scoped and cleared at each turn end. This cap bounds a
# home whose turn-end emitter never runs (telemetry enabled mid-session, a
# harness whose Stop hook is not registered) so the file cannot grow unbounded.
CS_TELEMETRY_MAX_CRUMBS=${CS_TELEMETRY_MAX_CRUMBS:-500}
# Largest transcript window read for one turn's usage. A larger window means the
# cursor fell far behind (a session that ran with telemetry off, a replaced
# transcript); skip the usage rather than read an unbounded file inside a hook.
CS_TELEMETRY_MAX_WINDOW_BYTES=${CS_TELEMETRY_MAX_WINDOW_BYTES:-4194304}
# Retention runs at most this often per home, at the turn-end boundary.
CS_TELEMETRY_PRUNE_INTERVAL=${CS_TELEMETRY_PRUNE_INTERVAL:-86400}
CS_TELEMETRY_RETAIN_DAYS_DEFAULT=30
# Breadcrumbs older than this cannot belong to the turn now ending, so the fold
# discards them rather than folding a dead session's leftovers into a live turn.
# It defers to CS_BUSY_TURN_MAX_SECS, the repo's existing "how long a pane may
# run busy with no completed turn" bound (bin/cs-watch.sh, docs/configuration.md,
# default 3600), because that is already the answer to "how long can one turn
# legitimately last here" and a second number would drift from it.
CS_TELEMETRY_MAX_CRUMB_AGE=${CS_BUSY_TURN_MAX_SECS:-3600}

# Every variable this library sets is pre-declared empty at load. Callers run
# under `set -u`, where reading an unset variable TERMINATES the shell - the one
# way a purely additive measurement library could still kill a spawn, a steer, or
# a turn-end hook. Pre-declaring makes that structurally impossible.
CS_TELEMETRY_HOST_DIR=
CS_TELEMETRY_DATA_DIR=
CS_TELEMETRY_STATE_DIR=
CS_TELEMETRY_CONF=
CS_TELEMETRY_DIR=
CS_TELEMETRY_FILE=
CS_TELEMETRY_CRUMBS=
CS_TELEMETRY_HOME=
CS_TELEMETRY_PURPOSE=
CS_TELEMETRY_OUTCOME=
CS_TELEMETRY_WAKE_KIND=
CS_TELEMETRY_USAGE=
CS_TELEMETRY_MODEL=
CS_TELEMETRY_EFFORT=
CS_TELEMETRY_DURATION_MS=
CS_TELEMETRY_SESSION_ID=
CS_TELEMETRY_WAKE_KINDS=
CS_TELEMETRY_SESSION_KEY=
CS_TELEMETRY_SESSION_KEY_RESOLVED=0
CS_TELEMETRY_RETAIN_DAYS=$CS_TELEMETRY_RETAIN_DAYS_DEFAULT

# The ancestry walk that names this session is bin/cs-session-pid-lib.sh's, not a
# second copy: breadcrumbs are keyed by exactly the identity the home lock
# already means by "this session". Sourcing it resolves no home, creates no
# directory, and takes no lock, so it is safe to pull into every telemetry
# caller. A checkout that somehow lacks it leaves the session key unresolvable,
# which drops breadcrumbs rather than failing anyone.
CS_TELEMETRY_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || CS_TELEMETRY_LIB_DIR=
if [ -n "$CS_TELEMETRY_LIB_DIR" ] && [ -r "$CS_TELEMETRY_LIB_DIR/cs-session-pid-lib.sh" ]; then
  # shellcheck source=bin/cs-session-pid-lib.sh
  . "$CS_TELEMETRY_LIB_DIR/cs-session-pid-lib.sh"
fi

# --- path resolution ---------------------------------------------------------
#
# bin/cs-root-lib.sh is the single owner of home resolution; this library defers
# to the values it already resolved (HOST_DIR, DATA, STATE) whenever the caller
# ran cs_resolve_root, and derives them from CS_HOME only for the callers that
# deliberately do not (bin/cs-send.sh resolves its own STATE and must not newly
# trip the layout gate). It never re-implements the override precedence.
cs_telemetry_paths() {
  local home=${CS_HOME:-${CS_ROOT:-}}
  [ -n "$home" ] || return 1
  CS_TELEMETRY_HOST_DIR=${HOST_DIR:-${CS_HOST_OVERRIDE:-$home/host}}
  CS_TELEMETRY_DATA_DIR=${DATA:-${CS_DATA_OVERRIDE:-$home/data}}
  CS_TELEMETRY_STATE_DIR=${STATE:-${CS_STATE_OVERRIDE:-$home/state}}
  CS_TELEMETRY_CONF="$CS_TELEMETRY_HOST_DIR/telemetry.conf"
  CS_TELEMETRY_DIR="$CS_TELEMETRY_DATA_DIR/telemetry"
  CS_TELEMETRY_FILE="$CS_TELEMETRY_DIR/turns.jsonl"
  CS_TELEMETRY_HOME=$home
  return 0
}

# cs_telemetry_session_key - print the identity of THIS consigliere session, or
# fail when it cannot be resolved.
#
# Breadcrumbs are turn-scoped state, and a home can hold more than one session at
# once: a second window, a read-only helper, or a tooling session started in the
# repo root all share the home. Keying the breadcrumb file by session is what
# stops one of them from reading, folding, or deleting another's in-flight
# breadcrumbs and mis-attributing a supervision turn.
#
# The identity is the harness process in this process's ancestry - the same one
# state/.lock already means by "this session" - because every breadcrumb site and
# the turn-end emitter run as descendants of it and so resolve the same pid.
#
# A bare pid is NOT enough, because pids recycle: a session that dropped
# breadcrumbs and then died without reaching a turn end leaves its file behind,
# and a much later session that happens to resolve the same number would fold a
# dead session's breadcrumbs into its own first turn - the same mis-attribution
# per-session keying exists to prevent, displaced in time instead of across
# concurrent sessions. So the key binds the pid to cs_pid_identity, the process
# start time (plus cmdline on Linux) that bin/cs-session-pid-lib.sh already owns
# precisely so a reused pid reads as a mismatch. That string carries spaces and
# slashes, so the key is `<pid>-<hash>`: the pid stays legible on disk and the
# hash makes a cross-session collision impossible in practice.
#
# An unresolvable identity yields NO key, so the breadcrumb is dropped. Falling
# back to a bare pid would reintroduce exactly the collision this guards against,
# and a dropped breadcrumb only costs one turn's classification.
#
# Resolved ONCE per process and cached: the walk costs up to sixteen `ps` calls,
# which a per-breadcrumb resolution would pay on every drained wake.
cs_telemetry_session_key() {
  local pid identity hash
  if [ "$CS_TELEMETRY_SESSION_KEY_RESOLVED" -eq 0 ]; then
    CS_TELEMETRY_SESSION_KEY_RESOLVED=1
    CS_TELEMETRY_SESSION_KEY=
    {
      if command -v cs_session_harness_pid >/dev/null 2>&1 &&
         command -v cs_pid_identity >/dev/null 2>&1; then
        pid=$(cs_session_harness_pid 2>/dev/null) || pid=
        case "$pid" in ''|*[!0-9]*) pid= ;; esac
        if [ -n "$pid" ]; then
          identity=$(cs_pid_identity "$pid" 2>/dev/null) || identity=
          if [ -n "$identity" ]; then
            hash=$(cs_telemetry_short_hash "$pid $identity") || hash=
            [ -n "$hash" ] && CS_TELEMETRY_SESSION_KEY="$pid-$hash"
          fi
        fi
      fi
    } 2>/dev/null || true
    case "$CS_TELEMETRY_SESSION_KEY" in
      *[!A-Za-z0-9-]*) CS_TELEMETRY_SESSION_KEY= ;;
    esac
  fi
  [ -n "$CS_TELEMETRY_SESSION_KEY" ] || return 1
  printf '%s\n' "$CS_TELEMETRY_SESSION_KEY"
}

# cs_telemetry_short_hash <string> - a short filesystem-safe digest, or nothing.
# The repo's established shasum/sha256sum pair; neither present means no key and
# therefore a dropped breadcrumb, never a guessable fallback.
cs_telemetry_short_hash() {
  local out=''
  if command -v shasum >/dev/null 2>&1; then
    out=$(printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print substr($1,1,16)}')
  elif command -v sha256sum >/dev/null 2>&1; then
    out=$(printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print substr($1,1,16)}')
  fi
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# cs_telemetry_crumbs_resolve - set CS_TELEMETRY_CRUMBS to THIS session's
# breadcrumb file, or clear it and fail. Telemetry is best-effort: a caller that
# cannot name its own session drops its breadcrumb rather than writing into a
# file another session would fold.
cs_telemetry_crumbs_resolve() {
  CS_TELEMETRY_CRUMBS=
  cs_telemetry_paths || return 1
  cs_telemetry_session_key >/dev/null || return 1
  CS_TELEMETRY_CRUMBS="$CS_TELEMETRY_STATE_DIR/.telemetry-crumbs-$CS_TELEMETRY_SESSION_KEY"
  return 0
}

# --- configuration -----------------------------------------------------------
#
# host/telemetry.conf is machine-local by contract: never portable config/
# material, never backed up or restored, never propagated into a capo home. A
# capo enables its own telemetry with its own host/telemetry.conf.
#
# Two whitespace-separated columns per record, the same shape as the other host
# configs. Blank lines and lines whose first field begins with # are ignored.
#
#   enabled      true|false      REQUIRED
#   retain_days  <1..3650>       optional; default 30
#
# Strict on purpose: an unknown key, a missing or extra field, a duplicate
# record, a bad value, or an absent `enabled` record is MALFORMED, which means
# disabled plus a doctor diagnostic. There is no partial enable.

# cs_telemetry_config_status - the one place that reads the config.
# Prints exactly one line: "disabled", "enabled <retain_days>", or
# "malformed <reason>". Never fails, never reads anything else.
cs_telemetry_config_status() {
  local key value extra normalized enabled='' retain='' seen_enabled=0 seen_retain=0
  if ! cs_telemetry_paths; then
    printf 'disabled\n'
    return 0
  fi
  if [ ! -e "$CS_TELEMETRY_CONF" ]; then
    printf 'disabled\n'
    return 0
  fi
  if [ ! -f "$CS_TELEMETRY_CONF" ] || [ ! -r "$CS_TELEMETRY_CONF" ]; then
    printf 'malformed not a readable regular file\n'
    return 0
  fi
  while read -r key value extra || [ -n "$key" ]; do
    case "$key" in ''|'#'*) continue ;; esac
    if [ -z "$value" ] || [ -n "$extra" ]; then
      printf 'malformed record "%s" is not exactly "<key> <value>"\n' "$key"
      return 0
    fi
    case "$key" in
      enabled)
        if [ "$seen_enabled" -ne 0 ]; then
          printf 'malformed duplicate enabled record\n'
          return 0
        fi
        seen_enabled=1
        case "$value" in
          true|false) enabled=$value ;;
          *)
            printf 'malformed enabled must be true or false, got "%s"\n' "$value"
            return 0
            ;;
        esac
        ;;
      retain_days)
        if [ "$seen_retain" -ne 0 ]; then
          printf 'malformed duplicate retain_days record\n'
          return 0
        fi
        seen_retain=1
        case "$value" in
          ''|*[!0-9]*)
            printf 'malformed retain_days must be a positive integer, got "%s"\n' "$value"
            return 0
            ;;
        esac
        # Normalize to one canonical base-10 integer HERE, the single place that
        # reads the config, so every consumer sees the same number. Left as
        # written, a leading zero means two different things downstream: bash
        # arithmetic reads "012" as octal 10 (and aborts outright on "09"), while
        # `find -mtime` reads it as 12. The record rewrite and the cursor sweep
        # must never disagree about the retention window.
        normalized=${value#"${value%%[!0]*}"}
        [ -n "$normalized" ] || normalized=0
        if [ "${#normalized}" -gt 4 ] || [ "$normalized" -lt 1 ] || [ "$normalized" -gt 3650 ]; then
          printf 'malformed retain_days must be between 1 and 3650, got "%s"\n' "$value"
          return 0
        fi
        retain=$normalized
        ;;
      *)
        printf 'malformed unknown key "%s"\n' "$key"
        return 0
        ;;
    esac
  done < "$CS_TELEMETRY_CONF"
  if [ "$seen_enabled" -eq 0 ]; then
    printf 'malformed no enabled record\n'
    return 0
  fi
  if [ "$enabled" != true ]; then
    printf 'disabled\n'
    return 0
  fi
  printf 'enabled %s\n' "${retain:-$CS_TELEMETRY_RETAIN_DAYS_DEFAULT}"
  return 0
}

# cs_telemetry_on - rc 0 only when telemetry is enabled AND usable (jq present).
# Resolves the paths in THIS shell (cs_telemetry_config_status runs in a command
# substitution, so its own resolution would stay in the subshell) and sets
# CS_TELEMETRY_RETAIN_DAYS for the caller. Never prints.
cs_telemetry_on() {
  local status
  CS_TELEMETRY_RETAIN_DAYS=$CS_TELEMETRY_RETAIN_DAYS_DEFAULT
  # CS_TELEMETRY_DISABLE is a test/escape seam, unset in production: it forces
  # telemetry off no matter what the config says. tests/lib.sh pins it for every
  # suite, because most suites resolve DATA to the real repo checkout and would
  # otherwise append test turns to a developer's own measurement dataset.
  if [ "${CS_TELEMETRY_DISABLE:-}" = 1 ]; then
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 1
  cs_telemetry_paths || return 1
  status=$(cs_telemetry_config_status 2>/dev/null) || return 1
  case "$status" in
    'enabled '*) CS_TELEMETRY_RETAIN_DAYS=${status#enabled } ;;
    *) return 1 ;;
  esac
  return 0
}

# --- breadcrumbs -------------------------------------------------------------
#
# A breadcrumb is a fact about what actually ran during the current turn, dropped
# by the script that ran it. The turn-end emitter folds them into one purpose and
# one outcome, then clears them. That keeps every call site trivial, keeps one
# owner of the folding rules, and keeps classification honest: it is derived from
# what executed, never from prose and never from a model call.
#
# Vocabulary (the folding table is below; docs/telemetry.md restates it for an
# analyst):
#   wake <kind>    one drained wake row of kind signal|stale|check|heartbeat
#   checkpoint     a bounded foreground supervision checkpoint ran
#   spawn <kind>   a soldier or capo was dispatched
#   steer          a direct report was messaged
#   merge          a PR merge or an approved local landing ran
#   teardown       a task was cleaned up
#   promote        a scout was promoted to ship

# cs_telemetry_discard_stale_crumbs - remove this session's breadcrumb file when
# it is older than one plausible turn, so the fold that follows sees nothing.
#
# This is the second half of the reuse defence, and it fails differently from the
# hashed session key: the key makes a collision impossible, this makes a dead
# session's leftovers short-lived whatever the key says. It also covers the
# ordinary case the retain_days sweep is far too slow for - a harness killed
# mid-turn leaves breadcrumbs that would otherwise sit for up to a month.
# Unreadable mtime means leave it alone; telemetry never destroys state it cannot
# prove is stale. Always rc 0.
cs_telemetry_discard_stale_crumbs() {
  local mtime now
  [ -n "$CS_TELEMETRY_CRUMBS" ] || return 0
  [ -f "$CS_TELEMETRY_CRUMBS" ] || return 0
  {
    mtime=$(cs_telemetry_mtime "$CS_TELEMETRY_CRUMBS")
    now=$(date -u +%s 2>/dev/null)
    case "$mtime" in ''|*[!0-9]*) return 0 ;; esac
    case "$now" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$((now - mtime))" -ge "$CS_TELEMETRY_MAX_CRUMB_AGE" ]; then
      rm -f "$CS_TELEMETRY_CRUMBS" 2>/dev/null || true
    fi
  } 2>/dev/null || true
  return 0
}

# cs_telemetry_crumb <kind> [detail] - record one breadcrumb in THIS session's
# own breadcrumb file. A session whose identity cannot be resolved drops the
# breadcrumb silently rather than writing where another session would fold it.
# Always rc 0.
cs_telemetry_crumb() {
  local kind=${1:-} detail=${2:-} lines
  [ -n "$kind" ] || return 0
  cs_telemetry_on || return 0
  cs_telemetry_crumbs_resolve || return 0
  {
    kind=$(printf '%s' "$kind" | LC_ALL=C tr -d '\t\r\n')
    detail=$(printf '%s' "$detail" | LC_ALL=C tr -d '\t\r\n')
    mkdir -p "$CS_TELEMETRY_STATE_DIR" 2>/dev/null || true
    if [ -f "$CS_TELEMETRY_CRUMBS" ]; then
      lines=$(wc -l < "$CS_TELEMETRY_CRUMBS" 2>/dev/null | tr -d ' ')
      case "$lines" in ''|*[!0-9]*) lines=0 ;; esac
      if [ "$lines" -ge "$CS_TELEMETRY_MAX_CRUMBS" ]; then
        : > "$CS_TELEMETRY_CRUMBS"
      fi
    fi
    printf '%s\t%s\n' "$kind" "$detail" >> "$CS_TELEMETRY_CRUMBS"
  } 2>/dev/null || true
  return 0
}

# --- record append -----------------------------------------------------------

cs_telemetry_event_id() {
  local id=''
  if command -v uuidgen >/dev/null 2>&1; then
    id=$(uuidgen 2>/dev/null | LC_ALL=C tr '[:upper:]' '[:lower:]')
  fi
  if [ -n "$id" ]; then
    printf '%s\n' "$id"
    return 0
  fi
  printf '%s-%s-%s%s\n' "$(date -u +%s 2>/dev/null)" "$$" "${RANDOM:-0}" "${RANDOM:-0}"
}

# cs_telemetry_emit <key=value>... - append exactly one record. Always rc 0.
#
# Recognized keys: role kind home project task_id harness model effort purpose
# wake_kind wake_kinds outcome duration_ms session_id usage. An omitted or empty
# key is recorded as null; `usage` takes a raw JSON object and `wake_kinds` a
# comma-separated list that is recorded as a JSON array. Unknown keys are
# ignored, so a caller can never invent a field outside the schema.
#
# The append is one printf of one line below CS_TELEMETRY_MAX_RECORD_BYTES to a
# file opened O_APPEND, which is what keeps concurrent emitters in the same home
# from interleaving a partial line. An over-cap record is dropped whole rather
# than truncated, because half a JSON line is worse than a missing one.
cs_telemetry_emit() {
  local pairs='' kv key val record nl
  cs_telemetry_on || return 0
  nl=$(printf '\n_')
  nl=${nl%_}
  {
    for kv in "$@"; do
      case "$kv" in
        *=*) ;;
        *) continue ;;
      esac
      key=${kv%%=*}
      val=${kv#*=}
      val=$(printf '%s' "$val" | LC_ALL=C tr -d '\r\n')
      pairs="$pairs$key=$val$nl"
    done
    record=$(
      jq -cn \
        --argjson schema "$CS_TELEMETRY_SCHEMA" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg eid "$(cs_telemetry_event_id)" \
        --arg pairs "$pairs" '
        def s($f; k): (($f[k] // "") | if . == "" then null else . end);
        def n($f; k): (($f[k] // "") | if . == "" then null else (tonumber? // null) end);
        ($pairs
         | split("\n")
         | map(select(contains("=")) | (index("=")) as $i | {key: .[:$i], value: .[$i+1:]})
         | from_entries) as $f
        | {
            schema: $schema,
            timestamp: $ts,
            event_id: $eid,
            role: s($f; "role"),
            kind: s($f; "kind"),
            home: s($f; "home"),
            project: s($f; "project"),
            task_id: s($f; "task_id"),
            harness: s($f; "harness"),
            model: s($f; "model"),
            effort: s($f; "effort"),
            purpose: s($f; "purpose"),
            wake_kind: s($f; "wake_kind"),
            wake_kinds: (($f["wake_kinds"] // "") | if . == "" then null else split(",") end),
            outcome: s($f; "outcome"),
            duration_ms: n($f; "duration_ms"),
            session_id: s($f; "session_id"),
            usage: (
              ((($f["usage"] // "") | if . == "" then null else (fromjson? // null) end) // {})
              | {
                  input_tokens: (.input_tokens // null),
                  cached_input_tokens: (.cached_input_tokens // null),
                  output_tokens: (.output_tokens // null),
                  reasoning_tokens: (.reasoning_tokens // null),
                  total_tokens: (.total_tokens // null)
                }
            )
          }'
    ) || record=
    if [ -n "$record" ] && [ "${#record}" -lt "$CS_TELEMETRY_MAX_RECORD_BYTES" ]; then
      mkdir -p "$CS_TELEMETRY_DIR" 2>/dev/null || true
      printf '%s\n' "$record" >> "$CS_TELEMETRY_FILE"
    fi
  } 2>/dev/null || true
  return 0
}

# --- the fold ----------------------------------------------------------------
#
# THE FOLDING RULES. This is the implementation and the only place they execute;
# docs/telemetry.md restates the table so a later analyst can tell exactly what
# `wait` versus `no_action` means in the data.
#
# Inputs: the breadcrumbs recorded during the turn, plus the emitting role.
#   W = the set of drained wake kinds        C = a checkpoint ran
#   A = the set of action crumbs (spawn, steer, merge, teardown, promote)
#
# purpose, first match wins:
#   1. W non-empty or C           -> supervision  (monitoring caused the turn)
#   2. spawn in A                 -> dispatch
#   3. merge|teardown|promote in A-> review       (delivery and landing work)
#   4. steer in A                 -> supervision  (messaging a live subordinate)
#   5. role = root                -> boss         (see the inference note below)
#   6. otherwise                  -> unknown
#
# outcome, recorded only when purpose = supervision, first match wins:
#   1. stale in W and A non-empty -> recovery_action  (a stale worker that did
#                                                      need intervention)
#   2. spawn in A                 -> dispatch_more
#   3. merge|teardown|promote in A-> completed
#   4. steer in A                 -> message_worker
#   5. W non-empty                -> no_action  (wakes reviewed, nothing done)
#   6. C and W empty              -> wait       (still working, keep monitoring)
#   7. otherwise                  -> unknown
#
# `escalate_up` and `technical_intervention` stay in the vocabulary but have no
# deterministic mechanical source, so schema 1 never emits them rather than
# guessing: bad telemetry is worse than missing telemetry.
#
# The one inference in the table is purpose rule 5, and it is a property of the
# operating contract rather than a guess about content: AGENTS.md section 8
# requires every wake-handling turn to drain the queue first and to hold exactly
# one live checkpoint while work is under way, so a ROOT turn that ran neither,
# and dispatched, steered, merged, tore down, or promoted nothing, supervised
# nothing. A capo turn with the same emptiness stays `unknown`, because a capo is
# idle by default and its turns arrive as work routed from the main home.
#
# Sets CS_TELEMETRY_PURPOSE, CS_TELEMETRY_OUTCOME, CS_TELEMETRY_WAKE_KIND,
# CS_TELEMETRY_WAKE_KINDS and clears THIS session's breadcrumbs - never another
# session's. A session whose identity cannot be resolved folds nothing and still
# records the turn, with a null wake kind: telemetry is best-effort and must
# never guess. Always rc 0.
cs_telemetry_fold() {
  local role=${1:-} kind detail seen='|' kinds=''
  local wake_count=0 first_wake='' checkpoint=0 stale=0
  local has_spawn=0 has_steer=0 has_close=0
  CS_TELEMETRY_PURPOSE=unknown
  CS_TELEMETRY_OUTCOME=
  CS_TELEMETRY_WAKE_KIND=
  CS_TELEMETRY_WAKE_KINDS=
  cs_telemetry_crumbs_resolve || CS_TELEMETRY_CRUMBS=
  cs_telemetry_discard_stale_crumbs
  if [ -n "$CS_TELEMETRY_CRUMBS" ] && [ -f "$CS_TELEMETRY_CRUMBS" ]; then
    while IFS="$(printf '\t')" read -r kind detail || [ -n "$kind" ]; do
      case "$kind" in
        wake)
          [ -n "$detail" ] || detail=other
          case "$seen" in
            *"|$detail|"*) ;;
            *)
              seen="$seen$detail|"
              wake_count=$((wake_count + 1))
              if [ "$wake_count" -eq 1 ]; then
                first_wake=$detail
                kinds=$detail
              else
                kinds="$kinds,$detail"
              fi
              ;;
          esac
          if [ "$detail" = stale ]; then
            stale=1
          fi
          ;;
        checkpoint) checkpoint=1 ;;
        spawn) has_spawn=1 ;;
        steer) has_steer=1 ;;
        merge|teardown|promote) has_close=1 ;;
      esac
    done < "$CS_TELEMETRY_CRUMBS"
    rm -f "$CS_TELEMETRY_CRUMBS" 2>/dev/null || true
  fi

  # wake_kind stays inside the queue's own vocabulary and names the FIRST kind
  # this turn drained, or `checkpoint` when the turn's only supervision was a
  # bounded foreground checkpoint, else null. wake_kinds is the additive record
  # of every distinct kind the turn drained, in drain order, so a multi-wake turn
  # stays fully recoverable without wake_kind leaving the vocabulary.
  if [ "$wake_count" -gt 0 ]; then
    CS_TELEMETRY_WAKE_KIND=$first_wake
    CS_TELEMETRY_WAKE_KINDS=$kinds
  elif [ "$checkpoint" -eq 1 ]; then
    CS_TELEMETRY_WAKE_KIND=checkpoint
  fi

  if [ "$wake_count" -gt 0 ] || [ "$checkpoint" -eq 1 ]; then
    CS_TELEMETRY_PURPOSE=supervision
  elif [ "$has_spawn" -eq 1 ]; then
    CS_TELEMETRY_PURPOSE=dispatch
  elif [ "$has_close" -eq 1 ]; then
    CS_TELEMETRY_PURPOSE=review
  elif [ "$has_steer" -eq 1 ]; then
    CS_TELEMETRY_PURPOSE=supervision
  elif [ "$role" = root ]; then
    CS_TELEMETRY_PURPOSE=boss
  fi

  if [ "$CS_TELEMETRY_PURPOSE" = supervision ]; then
    if [ "$stale" -eq 1 ] && [ "$((has_spawn + has_steer + has_close))" -gt 0 ]; then
      CS_TELEMETRY_OUTCOME=recovery_action
    elif [ "$has_spawn" -eq 1 ]; then
      CS_TELEMETRY_OUTCOME=dispatch_more
    elif [ "$has_close" -eq 1 ]; then
      CS_TELEMETRY_OUTCOME=completed
    elif [ "$has_steer" -eq 1 ]; then
      CS_TELEMETRY_OUTCOME=message_worker
    elif [ "$wake_count" -gt 0 ]; then
      CS_TELEMETRY_OUTCOME=no_action
    elif [ "$checkpoint" -eq 1 ]; then
      CS_TELEMETRY_OUTCOME='wait'
    else
      CS_TELEMETRY_OUTCOME=unknown
    fi
  fi
  return 0
}

# --- harness usage extraction ------------------------------------------------
#
# Both harnesses hand the Stop hook a `transcript_path` (verified live
# 2026-08-08; docs/codex.md and docs/claude.md record the exact payloads).
# Neither reports a per-turn total directly, so the window between this turn end
# and the previous one is read from a per-session byte cursor and the usage in it
# summed. Only numbers, the model, and the effort ever leave that read: no
# message text, no tool output, no file contents, ever.
#
# state/.telemetry-cursor-<session> holds "<byte-offset><TAB><effort><TAB><model>".
# It is disposable; deleting one costs one turn of usage attribution.
#
# Sets CS_TELEMETRY_USAGE (a JSON object or empty), CS_TELEMETRY_MODEL,
# CS_TELEMETRY_EFFORT, CS_TELEMETRY_DURATION_MS, CS_TELEMETRY_SESSION_ID.
# Always rc 0; every unavailable value stays empty and is recorded as null.
cs_telemetry_usage() {
  local harness=${1:-} payload=${2:-}
  local transcript session cursor offset size window result prev_effort prev_model
  CS_TELEMETRY_USAGE=
  CS_TELEMETRY_MODEL=
  CS_TELEMETRY_EFFORT=
  CS_TELEMETRY_DURATION_MS=
  CS_TELEMETRY_SESSION_ID=
  [ -n "$payload" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  cs_telemetry_paths || return 0
  {
    session=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
    transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)
    CS_TELEMETRY_SESSION_ID=$session
    case "$harness" in
      claude) CS_TELEMETRY_EFFORT=$(printf '%s' "$payload" | jq -r '.effort.level // empty' 2>/dev/null) ;;
      codex) CS_TELEMETRY_MODEL=$(printf '%s' "$payload" | jq -r '.model // empty' 2>/dev/null) ;;
      # An unnamed harness has no parser, so the whole read stops HERE, before
      # the cursor is touched. Advancing the cursor and then failing to parse
      # would silently forfeit that window's tokens for the next turn too, even
      # one whose payload is perfectly unambiguous. The session id above is still
      # authoritative and is kept.
      *) return 0 ;;
    esac

    [ -n "$session" ] || return 0
    [ -n "$transcript" ] || return 0
    [ -f "$transcript" ] || return 0
    case "$session" in *[!A-Za-z0-9._-]*) return 0 ;; esac
    cursor="$CS_TELEMETRY_STATE_DIR/.telemetry-cursor-$session"
    offset=0
    prev_effort=
    prev_model=
    if [ -f "$cursor" ]; then
      IFS="$(printf '\t')" read -r offset prev_effort prev_model < "$cursor" || offset=0
    fi
    case "$offset" in ''|*[!0-9]*) offset=0 ;; esac
    # Carry forward what this session already stated authoritatively, so a turn
    # whose window carries no new record still names its model and effort. Each
    # harness leaves one of the two out of its Stop payload, and the payload
    # always wins where it does carry one.
    [ -n "$CS_TELEMETRY_EFFORT" ] || CS_TELEMETRY_EFFORT=$prev_effort
    [ -n "$CS_TELEMETRY_MODEL" ] || CS_TELEMETRY_MODEL=$prev_model
    size=$(wc -c < "$transcript" 2>/dev/null | tr -d ' ')
    case "$size" in ''|*[!0-9]*) return 0 ;; esac
    # A shrunken file means the transcript was replaced or rotated; restart.
    [ "$offset" -le "$size" ] || offset=0
    mkdir -p "$CS_TELEMETRY_STATE_DIR" 2>/dev/null || true
    printf '%s\t%s\t%s\n' "$size" "$CS_TELEMETRY_EFFORT" "$CS_TELEMETRY_MODEL" \
      > "$cursor" 2>/dev/null || true
    [ "$size" -gt "$offset" ] || return 0
    [ "$((size - offset))" -le "$CS_TELEMETRY_MAX_WINDOW_BYTES" ] || return 0
    window=$(tail -c "+$((offset + 1))" "$transcript" 2>/dev/null)
    [ -n "$window" ] || return 0

    case "$harness" in
      codex) result=$(printf '%s\n' "$window" | cs_telemetry_usage_codex) ;;
      *) result=$(printf '%s\n' "$window" | cs_telemetry_usage_claude) ;;
    esac
    [ -n "$result" ] || return 0
    CS_TELEMETRY_USAGE=$(printf '%s' "$result" | jq -c '.usage' 2>/dev/null)
    CS_TELEMETRY_DURATION_MS=$(printf '%s' "$result" | jq -r '.duration_ms // empty' 2>/dev/null)
    [ -n "$CS_TELEMETRY_MODEL" ] || CS_TELEMETRY_MODEL=$(printf '%s' "$result" | jq -r '.model // empty' 2>/dev/null)
    [ -n "$CS_TELEMETRY_EFFORT" ] || CS_TELEMETRY_EFFORT=$(printf '%s' "$result" | jq -r '.effort // empty' 2>/dev/null)
    # Re-persist the cursor with whatever this window resolved, so the next turn
    # inherits it. The window is the only place claude states its model and the
    # only place codex states its effort.
    printf '%s\t%s\t%s\n' "$size" "$CS_TELEMETRY_EFFORT" "$CS_TELEMETRY_MODEL" \
      > "$cursor" 2>/dev/null || true
  } 2>/dev/null || true
  return 0
}

# Codex rollout window -> {usage, duration_ms, model, effort} on stdout.
# `event_msg`/`token_count` carries info.last_token_usage per model request, so a
# turn's usage is their sum; `event_msg`/`task_complete` carries the turn's own
# duration_ms; `turn_context` carries the model and the reasoning effort. The
# field names are codex's own, so the normalized shape is a rename, not a guess.
cs_telemetry_usage_codex() {
  jq -R -n '
    def num(v): (v | if type == "number" then . else null end);
    [inputs | fromjson? | select(type == "object")] as $rows
    | [$rows[] | select(.payload.type == "token_count")
       | .payload.info.last_token_usage | select(type == "object")] as $tok
    | ([$rows[] | select(.payload.type == "task_complete") | num(.payload.duration_ms)
        | select(. != null)] | last) as $dur
    | ([$rows[] | select(.type == "turn_context") | .payload.model
        | select(type == "string")] | last) as $model
    | ([$rows[] | select(.type == "turn_context") | .payload.effort
        | select(type == "string")] | last) as $effort
    | def sum(f): ([$tok[] | f | select(type == "number")] | if length == 0 then null else add end);
      if ($tok | length) == 0 and $dur == null then empty else
        {
          usage: {
            input_tokens: sum(.input_tokens),
            cached_input_tokens: sum(.cached_input_tokens),
            output_tokens: sum(.output_tokens),
            reasoning_tokens: sum(.reasoning_output_tokens),
            total_tokens: sum(.total_tokens)
          },
          duration_ms: $dur,
          model: $model,
          effort: $effort
        }
      end' 2>/dev/null
}

# Claude transcript window -> {usage, duration_ms, model, effort} on stdout.
#
# Two normalizations, both called out in docs/telemetry.md as the places where
# attribution is deliberately approximate:
#   1. The transcript records several streaming snapshots of one assistant
#      message, all carrying the SAME message.id and the same final usage, so
#      usage is deduplicated by message.id and only the last snapshot of each id
#      is summed. Summing rows blind would multiply a turn's tokens severalfold.
#   2. Anthropic reports input_tokens EXCLUDING cache reads and cache writes,
#      while codex reports an input total with the cached part as a subset. The
#      normalized input_tokens is therefore input + cache_creation + cache_read,
#      so both harnesses mean the same thing in one dataset. Claude does not
#      report reasoning tokens separately (they sit inside output_tokens), so
#      reasoning_tokens is null rather than invented.
# duration_ms is the wall span of the window's own record timestamps.
cs_telemetry_usage_claude() {
  jq -R -n '
    def ms: capture("^(?<b>[^.]+)(\\.(?<f>[0-9]+))?Z$")
      | (((.b + "Z") | fromdateiso8601) * 1000) + (((.f // "0") + "000")[0:3] | tonumber);
    [inputs | fromjson? | select(type == "object")] as $rows
    | ([$rows[] | select(.type == "assistant") | select(.message.id | type == "string")]
       | group_by(.message.id) | map(last)) as $msgs
    | [$rows[] | .timestamp | select(type == "string") | (try ms catch empty)] as $stamps
    | ([$msgs[] | .message.model | select(type == "string")] | last) as $model
    | ([$rows[] | .effort | select(type == "string")] | last) as $effort
    | def sum(f): ([$msgs[] | .message.usage | f | select(type == "number")] | add // 0);
      if ($msgs | length) == 0 then empty else
        (sum(.input_tokens) + sum(.cache_creation_input_tokens) + sum(.cache_read_input_tokens)) as $in
        | sum(.output_tokens) as $out
        | {
            usage: {
              input_tokens: $in,
              cached_input_tokens: sum(.cache_read_input_tokens),
              output_tokens: $out,
              reasoning_tokens: null,
              total_tokens: ($in + $out)
            },
            duration_ms: (if ($stamps | length) > 1 then (($stamps | max) - ($stamps | min)) else null end),
            model: $model,
            effort: $effort
          }
      end' 2>/dev/null
}

# --- turn end ----------------------------------------------------------------

# cs_telemetry_payload_harness [payload] - print the harness that actually
# produced this turn, derived from the Stop payload's own shape, or nothing.
#
# The payload is the authority here. host/harness.conf pins what consigliere
# DISPATCHES with and is no evidence about the harness that ran the turn being
# measured, so a home pinned to one harness while the boss runs the other would
# otherwise record a wrong harness identity AND feed the transcript to the wrong
# parser, yielding null usage under a confident wrong label.
#
# The two payloads distinguish themselves and both shapes are recorded as
# verified facts: a codex Stop payload carries `turn_id` (docs/codex.md), a
# claude Stop payload carries `prompt_id` (docs/claude.md). A payload that
# carries both, neither, or nothing at all is genuinely ambiguous, and an
# ambiguous harness is recorded as null rather than guessed - which also skips
# usage extraction, because a null is honest and a wrong harness is not.
cs_telemetry_payload_harness() {
  local payload=${1:-} harness
  [ -n "$payload" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  harness=$(printf '%s' "$payload" | jq -r '
    if type != "object" then empty
    elif (has("turn_id") and (has("prompt_id") | not)) then "codex"
    elif (has("prompt_id") and (has("turn_id") | not)) then "claude"
    else empty end' 2>/dev/null) || harness=
  case "$harness" in
    codex|claude) printf '%s\n' "$harness" ;;
  esac
  return 0
}

# cs_telemetry_turn_end <role> [payload] - the supervisor turn-end emitter.
# <role> is root or capo; <payload> is the harness Stop payload (may be empty).
# Folds this session's breadcrumbs, names the emitting harness from the payload
# shape, extracts whatever usage that harness makes authoritatively available,
# appends one record, and runs bounded retention.
# Always rc 0 and completely silent.
cs_telemetry_turn_end() {
  local role=${1:-} payload=${2:-} harness='' capo_id='' kind=''
  cs_telemetry_on || return 0
  {
    cs_telemetry_paths || return 0
    harness=$(cs_telemetry_payload_harness "$payload")
    cs_telemetry_fold "$role"
    cs_telemetry_usage "$harness" "$payload"
    # A capo home names itself in its own marker, so a capo turn carries its own
    # capo id without reaching into the parent home that dispatched it.
    if [ "$role" = capo ]; then
      kind=capo
      if [ -f "$CS_TELEMETRY_HOME/.cs-capo-home" ]; then
        IFS= read -r capo_id < "$CS_TELEMETRY_HOME/.cs-capo-home" 2>/dev/null || capo_id=
        capo_id=${capo_id//[[:space:]]/}
      fi
    fi
    cs_telemetry_emit \
      "role=$role" \
      "kind=$kind" \
      "home=$CS_TELEMETRY_HOME" \
      "task_id=$capo_id" \
      "harness=$harness" \
      "model=$CS_TELEMETRY_MODEL" \
      "effort=$CS_TELEMETRY_EFFORT" \
      "purpose=$CS_TELEMETRY_PURPOSE" \
      "wake_kind=$CS_TELEMETRY_WAKE_KIND" \
      "wake_kinds=$CS_TELEMETRY_WAKE_KINDS" \
      "outcome=$CS_TELEMETRY_OUTCOME" \
      "duration_ms=$CS_TELEMETRY_DURATION_MS" \
      "session_id=$CS_TELEMETRY_SESSION_ID" \
      "usage=$CS_TELEMETRY_USAGE"
    cs_telemetry_prune
  } 2>/dev/null || true
  return 0
}

# cs_telemetry_worker_turn_end <task-id> [payload] - the worker turn-end emitter,
# called from the harness turn-end wiring of a ship or scout soldier. Role, kind,
# project, and harness come from the authoritative state/<id>.meta that
# cs-spawn.sh wrote; the model and the effort come only from the harness session
# itself, because consigliere selects neither. Nothing is re-derived and nothing
# is invented. A worker turn records no breadcrumbs and no supervision outcome: a
# soldier does not supervise, and its purpose follows from its task kind.
# Always rc 0.
cs_telemetry_worker_turn_end() {
  local id=${1:-} payload=${2:-} meta kind harness project purpose
  [ -n "$id" ] || return 0
  case "$id" in *[!A-Za-z0-9._-]*) return 0 ;; esac
  cs_telemetry_on || return 0
  {
    cs_telemetry_paths || return 0
    meta="$CS_TELEMETRY_STATE_DIR/$id.meta"
    [ -f "$meta" ] || return 0
    kind=$(awk -F= '$1 == "kind" { v = $2 } END { print v }' "$meta" 2>/dev/null)
    harness=$(awk -F= '$1 == "harness" { v = $2 } END { print v }' "$meta" 2>/dev/null)
    project=$(awk '/^project=/ { v = substr($0, 9) } END { print v }' "$meta" 2>/dev/null)
    if [ -n "$project" ]; then
      project=$(basename "$project")
    fi
    case "$kind" in
      ship) purpose=implementation ;;
      scout) purpose=research ;;
      *) purpose=unknown ;;
    esac
    cs_telemetry_usage "$harness" "$payload"
    cs_telemetry_emit \
      "role=$kind" \
      "kind=$kind" \
      "home=$CS_TELEMETRY_HOME" \
      "project=$project" \
      "task_id=$id" \
      "harness=$harness" \
      "model=$CS_TELEMETRY_MODEL" \
      "effort=$CS_TELEMETRY_EFFORT" \
      "purpose=$purpose" \
      "duration_ms=$CS_TELEMETRY_DURATION_MS" \
      "session_id=$CS_TELEMETRY_SESSION_ID" \
      "usage=$CS_TELEMETRY_USAGE"
  } 2>/dev/null || true
  return 0
}

# cs_telemetry_worker_hook_command <task-id> <bin-dir> <stdin|nostdin> - print the
# command a ship or scout soldier's turn-end wiring runs to record its own turn,
# or nothing at all when telemetry is off or the command could not be built
# safely. Command construction lives here because this library owns the format;
# bin/cs-harness-lib.sh only places the string in each harness's wiring.
#
# `stdin` is for claude, whose launch-scoped Stop hook feeds the payload (and its
# transcript_path) to every hook command. `nostdin` is for codex, whose `notify`
# program is invoked with an argument and no piped payload - the emitter must not
# read stdin there or it would block the soldier's turn-end wiring forever.
#
# The string is embedded inside a JSON string in both harnesses' wiring, so a
# command carrying a double quote or a backslash - which only a home or repo path
# containing a single quote could produce - is refused rather than emitted
# malformed. Losing worker telemetry for such a path is the safe direction; a
# corrupted turn-end hook is not.
cs_telemetry_worker_hook_command() {
  local id=${1:-} bindir=${2:-} mode=${3:-nostdin} cmd
  [ -n "$id" ] || return 0
  [ -n "$bindir" ] || return 0
  cs_telemetry_on || return 0
  cmd="CS_HOME=$(cs_telemetry_quote "$CS_TELEMETRY_HOME") $(cs_telemetry_quote "$bindir/cs-telemetry-emit.sh") --worker --task $(cs_telemetry_quote "$id")"
  if [ "$mode" = stdin ]; then
    cmd="$cmd --stdin"
  fi
  case "$cmd" in
    *'"'*|*\\*) return 0 ;;
  esac
  printf '%s\n' "$cmd"
}

# cs_telemetry_quote <s> - single-quote a value for safe shell embedding.
# Deliberately a local copy rather than a dependency on bin/cs-harness-lib.sh:
# this library is sourced by callers that have no reason to load the harness
# layer, and quoting one argument is not a contract worth coupling them over.
cs_telemetry_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# --- retention ---------------------------------------------------------------
#
# One mechanism, no database and no compaction: records older than retain_days
# are dropped from the file. It runs at the turn-end boundary that already
# exists, at most once per CS_TELEMETRY_PRUNE_INTERVAL per home, behind a
# non-blocking lock. It can never block, delay, or interfere with supervision: a
# held lock, a missing jq, an unwritable directory, or any other obstacle skips
# silently and the next turn end tries again.
#
# The lock is released two ways, because retention that stops running is
# retention that does not exist. An EXIT trap inside the locked SUBSHELL releases
# it on any ordinary abnormal exit without ever touching the caller's own traps,
# and a lock directory older than one prune interval is reclaimed on the next
# attempt, which covers a hard kill (a Stop-hook timeout) that no trap can catch.
# A genuinely held FRESH lock is still skipped silently.

# Portable mtime in epoch seconds. A deliberate local copy rather than a
# dependency on bin/cs-lock-lib.sh, for the same reason cs_telemetry_quote is:
# this library is sourced by callers with no reason to load the git-lock layer.
cs_telemetry_mtime() {
  if [ "$(uname 2>/dev/null)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

cs_telemetry_prune() {
  local stamp lock now last age
  cs_telemetry_on || return 0
  {
    cs_telemetry_paths || return 0
    [ -d "$CS_TELEMETRY_DIR" ] || return 0
    stamp="$CS_TELEMETRY_DIR/.pruned"
    lock="$CS_TELEMETRY_DIR/.prune.lock"
    now=$(date -u +%s 2>/dev/null)
    case "$now" in ''|*[!0-9]*) return 0 ;; esac
    if [ -f "$stamp" ]; then
      last=$(cat "$stamp" 2>/dev/null)
      case "$last" in ''|*[!0-9]*) last=0 ;; esac
      [ "$((now - last))" -ge "$CS_TELEMETRY_PRUNE_INTERVAL" ] || return 0
    fi
    # Reclaim a leaked lock before trying to take one. A lock older than a whole
    # prune interval cannot belong to a live prune: this function's own work is
    # bounded by one jq pass and one find.
    if [ -d "$lock" ]; then
      age=$(cs_telemetry_mtime "$lock")
      case "$age" in
        ''|*[!0-9]*) ;;
        *)
          if [ "$((now - age))" -ge "$CS_TELEMETRY_PRUNE_INTERVAL" ]; then
            rmdir "$lock" 2>/dev/null || true
          fi
          ;;
      esac
    fi
    mkdir "$lock" 2>/dev/null || return 0
    printf '%s\n' "$now" > "$stamp" 2>/dev/null || true
    (
      trap 'rmdir "$lock" 2>/dev/null || true' EXIT
      cs_telemetry_prune_locked "$now"
    ) 2>/dev/null || true
  } 2>/dev/null || true
  return 0
}

# cs_telemetry_prune_locked <now-epoch> - the retention work itself, run only
# while this process holds the prune lock. Split out so the lock release is one
# trap on one subshell rather than a release that every early exit must remember.
cs_telemetry_prune_locked() {
  local now=$1 cutoff tmp size_before size_after lines_before lines_after
  if [ -f "$CS_TELEMETRY_FILE" ]; then
    cutoff=$((now - CS_TELEMETRY_RETAIN_DAYS * 86400))
    tmp="$CS_TELEMETRY_FILE.prune.$$"
    size_before=$(wc -c < "$CS_TELEMETRY_FILE" 2>/dev/null | tr -d ' ')
    lines_before=$(wc -l < "$CS_TELEMETRY_FILE" 2>/dev/null | tr -d ' ')
    if jq -R -c --argjson cutoff "$cutoff" '
          fromjson? // empty
          | select(type == "object")
          | select(((.timestamp // "") | try fromdateiso8601 catch 0) >= $cutoff)
        ' < "$CS_TELEMETRY_FILE" > "$tmp" 2>/dev/null; then
      lines_after=$(wc -l < "$tmp" 2>/dev/null | tr -d ' ')
      if [ -n "$lines_before" ] && [ "$lines_before" = "$lines_after" ]; then
        # Nothing aged out, so the rewrite would replace the file with its own
        # content. Skip it: every rename over a file that unlocked emitters are
        # appending to can only lose records, never gain any, and retention is
        # not worth spending that risk on a no-op. A concurrent append can only
        # inflate lines_before, so equality is a sound proof that this pass drops
        # nothing - it never hides a record that was due to age out.
        rm -f "$tmp" 2>/dev/null || true
      else
        # Compare and swap on size. Emitters append without taking this lock, by
        # design: an append must never wait on retention. So the rewrite is only
        # allowed to replace a file that nobody appended to while it was being
        # filtered - otherwise this rename would silently drop those records. A
        # detected append abandons the rewrite and the next interval retries.
        size_after=$(wc -c < "$CS_TELEMETRY_FILE" 2>/dev/null | tr -d ' ')
        if [ -n "$size_before" ] && [ "$size_before" = "$size_after" ]; then
          mv "$tmp" "$CS_TELEMETRY_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
        else
          rm -f "$tmp" 2>/dev/null || true
        fi
      fi
    else
      rm -f "$tmp" 2>/dev/null || true
    fi
  fi

  # The per-session transcript cursors and breadcrumb files age out on the same
  # schedule. Each one is tiny, but a home accumulates one of each per harness
  # session forever otherwise, and neither can bound anything that is still
  # recorded once it is older than the retention window. CS_TELEMETRY_RETAIN_DAYS
  # is normalized to base 10 at parse time, so this sweep and the record rewrite
  # above always mean the same number of days.
  if [ -d "$CS_TELEMETRY_STATE_DIR" ]; then
    find "$CS_TELEMETRY_STATE_DIR" -maxdepth 1 -type f \
      \( -name '.telemetry-cursor-*' -o -name '.telemetry-crumbs-*' \) \
      -mtime "+$CS_TELEMETRY_RETAIN_DAYS" -exec rm -f {} + 2>/dev/null || true
  fi
  return 0
}
