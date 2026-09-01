# shellcheck shell=bash
# Shared identity, ownership, durable capture, and publication rules for the
# process-event runner.
# Usage: . bin/cs-procevent-lib.sh   (requires cs-pr-lib.sh and cs-wake-lib.sh)
#
# The runner lets consigliere learn that a registered BLOCKING source produced a
# result without holding that process in a conversational turn. It is
# domain-neutral: a thin adapter supplies source identity, the argv to run, and
# whether a completed result ends the source. Ownership, durable capture,
# publication, and restart recovery live here.
#
# It adds no second notification control plane. A completed result is published
# as an ordinary `check` wake on the existing durable queue, which the bounded
# checkpoint, the persistent monitor, and self-activation all already read.
#
# DURABILITY BOUNDARY, stated precisely. This runner proves exactly one thing:
# once a child has exited and its output has been read, that output is stored
# atomically at mode 0600 BEFORE any event referencing it is published, and a
# captured result with no durable handled acknowledgement stays eligible for
# re-announcement - including across a restart between publication and handling -
# until `bin/cs-procevent.sh handled` records it. It proves nothing about the
# source side of the handoff. The published `lavish-axi poll` destructively
# clears feedback before returning it, so a result lost between that clearing
# and this runner reading the process output is unrecoverable, and no wrapper
# here can close that window. Marking a result handled also says nothing about
# whether a paired external effect performed before that call completed. Never
# describe this runner as at-least-once, no-loss, or lossless.

# Machine-wide claim root. One machine runs a main home plus N capo homes
# against a shared source store, so "one owner per canonical source" cannot live
# inside a single home's state.
cs_procevent_claim_root() {
  printf '%s\n' "${CS_PROCEVENT_CLAIM_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/consigliere/procevent-claims}"
}

cs_procevent_registry_dir() { printf '%s\n' "$1/procevent"; }
cs_procevent_inbox_dir()    { printf '%s\n' "$1/procevent-inbox"; }

# A source id names private files and a bounded wake slug, so it is held to the
# same path-safe shape as a task id. Adapters derive it from canonical source
# identity, never from a caller-supplied display string.
cs_procevent_source_id_valid() {
  local id=${1-}
  cs_task_id_path_safe "$id" || return 1
  [ "${#id}" -le 64 ]
}

cs_procevent_adapter_valid() {
  local a=${1-}
  case "$a" in
    ''|*[!a-z0-9-]*) return 1 ;;
  esac
  [ "${#a}" -le 32 ]
}

# cs_procevent_any_registered <state>: true while this home has an armed source.
# This is what makes an armed source count as work needing supervision, so a home
# whose only in-flight work is a blocking source is never told supervision is
# unnecessary.
cs_procevent_any_registered() {
  local reg rec
  reg=$(cs_procevent_registry_dir "$1")
  [ -d "$reg" ] || return 1
  for rec in "$reg"/*.source; do
    [ -e "$rec" ] || continue
    return 0
  done
  return 1
}

# cs_procevent_needs_reconcile <state>: true when this home has anything the
# watcher's per-cycle reconcile could act on. A home that never armed a source
# pays one directory test per cycle.
cs_procevent_needs_reconcile() {
  local reg inbox path
  reg=$(cs_procevent_registry_dir "$1")
  if [ -d "$reg" ]; then
    for path in "$reg"/*.source "$reg"/*.runner; do
      { [ -e "$path" ] || [ -L "$path" ]; } && return 0
    done
  fi
  inbox=$(cs_procevent_inbox_dir "$1")
  if [ -d "$inbox" ]; then
    for path in "$inbox"/*.result; do
      [ -f "$path" ] || continue
      [ -e "${path%.result}.handled" ] && continue
      return 0
    done
  fi
  return 1
}

# --- ownership --------------------------------------------------------------
# A claim is a private file recording the owning home, the runner pid, the claim
# generation token, the runner's process identity, and the registration it was
# taken against. Registration and every ownership transition are serialized at
# one machine-wide per-source boundary.

cs_procevent_claim_path() {
  printf '%s/%s.claim\n' "$(cs_procevent_claim_root)" "$1"
}

cs_procevent_source_lock_path() {
  printf '%s/%s.lock\n' "$(cs_procevent_claim_root)" "$1"
}

cs_procevent_source_lock_acquire() {
  local id=$1 root
  cs_procevent_source_id_valid "$id" || return 1
  root=$(cs_procevent_claim_root)
  (umask 077; mkdir -p "$root") || return 1
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  cs_lock_acquire_wait "$(cs_procevent_source_lock_path "$id")"
}

cs_procevent_source_lock_release() {
  cs_lock_release "$(cs_procevent_source_lock_path "$1")"
}

# Publish a source registration while the caller holds the source lock.
cs_procevent_registration_publish_locked() {  # <state> <adapter> <source-id> <argv...>
  local state=$1 adapter=$2 id=$3 reg dest tmp arg
  shift 3
  cs_procevent_adapter_valid "$adapter" || return 1
  cs_procevent_source_id_valid "$id" || return 1
  [ "$#" -ge 1 ] || return 1
  for arg in "$@"; do
    case "$arg" in *$'\n'*) return 1 ;; esac
  done
  reg=$(cs_procevent_registry_dir "$state")
  (umask 077; mkdir -p "$reg") || return 1
  [ -d "$reg" ] && [ ! -L "$reg" ] || return 1
  dest="$reg/$id.source"
  tmp=$(umask 077; mktemp "$reg/.source.XXXXXX") || return 1
  if {
    printf 'adapter=%s\n' "$adapter"
    printf 'argc=%s\n' "$#"
    printf 'argv:\n'
    printf '%s\n' "$@"
  } > "$tmp" && chmod 0600 "$tmp" && mv -f -- "$tmp" "$dest"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# One claim record: home, pid, token, pid-identity, registration dir,
# registration file identity, retirement state. Exactly seven lines, all
# required - consigliere ships one claim format, so an unreadable claim is a
# refusal, never a backfill.
cs_procevent_claim_load_locked() {  # <source-id>
  local claim home pid token identity reg_dir reg_identity terminal extra
  claim=$(cs_procevent_claim_path "$1")
  [ -f "$claim" ] && [ ! -L "$claim" ] || return 1
  {
    IFS= read -r home \
      && IFS= read -r pid \
      && IFS= read -r token \
      && IFS= read -r identity \
      && IFS= read -r reg_dir \
      && IFS= read -r reg_identity \
      && IFS= read -r terminal \
      && ! IFS= read -r extra
  } < "$claim" || return 1
  [ -n "$home" ] || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -n "$identity" ] || return 1
  case "$reg_dir" in /*) ;; *) return 1 ;; esac
  case "$reg_identity" in *:*) ;; *) return 1 ;; esac
  case "$terminal" in active|terminal) ;; *) return 1 ;; esac
  CS_PROCEVENT_CLAIM_HOME=$home
  CS_PROCEVENT_CLAIM_PID=$pid
  CS_PROCEVENT_CLAIM_TOKEN=$token
  CS_PROCEVENT_CLAIM_IDENTITY=$identity
  CS_PROCEVENT_CLAIM_REG_DIR=$reg_dir
  CS_PROCEVENT_CLAIM_REG_IDENTITY=$reg_identity
  CS_PROCEVENT_CLAIM_TERMINAL=$terminal
}

# cs_procevent_group_alive <pid>
# True while any process remains in the process group a runner leads. A runner
# is its own group leader, so this distinguishes a generation that is really
# gone from one whose leader died while its blocking child kept running.
cs_procevent_group_alive() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 -"$1" 2>/dev/null
}

# cs_procevent_pid_state <pid> <identity>
# 0 live match, 1 stale, 2 uncertain, 3 orphaned group.
#
# State 3 is the crash cut: the leader is gone but its owned group still has
# members, so the old generation can still be consuming the source. Treating
# that as stale would release ownership and let a second poller start against
# one canonical source. Only an ABSENT leader reaches state 3, which is also
# what makes signalling that group safe: a reused pid leaves the leader alive,
# so the identity comparison classifies it stale or uncertain instead and no
# group signal ever follows.
cs_procevent_pid_state() {
  local pid=$1 expected=$2 actual
  if ! cs_pid_alive "$pid"; then
    cs_procevent_group_alive "$pid" && return 3
    return 1
  fi
  if actual=$(cs_pid_identity "$pid" 2>/dev/null); then
    [ "$actual" = "$expected" ] && return 0
    return 1
  fi
  cs_pid_alive "$pid" || { cs_procevent_group_alive "$pid" && return 3; return 1; }
  return 2
}

# <source-id>: 0 live, 1 stale/absent, 2 uncertain, 3 leader gone with its owned
# process group still alive, 4 terminal retirement pending.
cs_procevent_claim_state_locked() {
  local claim registration current_identity
  claim=$(cs_procevent_claim_path "$1")
  [ -e "$claim" ] || return 1
  cs_procevent_claim_load_locked "$1" || return 2
  if [ "$CS_PROCEVENT_CLAIM_TERMINAL" = terminal ]; then
    registration="$CS_PROCEVENT_CLAIM_REG_DIR/$1.source"
    current_identity=$(cs_pr_file_identity "$registration" 2>/dev/null || true)
    [ "$current_identity" = "$CS_PROCEVENT_CLAIM_REG_IDENTITY" ] && return 4
  fi
  cs_procevent_pid_state "$CS_PROCEVENT_CLAIM_PID" "$CS_PROCEVENT_CLAIM_IDENTITY"
}

# cs_procevent_claim_acquire_locked <source-id> <home> <pid> <registration>
# 0 acquired, 1 error, 2 held by a live owner (possibly another home).
cs_procevent_claim_acquire_locked() {
  local id=$1 home=$2 pid=$3 registration=$4
  local root claim tmp identity token status claim_state old_reg_dir old_token
  cs_procevent_source_id_valid "$id" || return 1
  [ -f "$registration" ] && [ ! -L "$registration" ] || return 1
  local reg_dir=${registration%/*} reg_identity
  case "$reg_dir" in /*) ;; *) return 1 ;; esac
  reg_identity=$(cs_pr_file_identity "$registration" 2>/dev/null) || return 1
  identity=$(cs_pid_identity "$pid" 2>/dev/null) || return 1
  root=$(cs_procevent_claim_root)
  claim=$(cs_procevent_claim_path "$id")
  status=0
  if [ -e "$claim" ] || [ -L "$claim" ]; then
    cs_procevent_claim_state_locked "$id"
    claim_state=$?
    case "$claim_state" in
      0|2|3|4) status=2 ;;
      1)
        if [ -f "$claim" ] && [ ! -L "$claim" ]; then
          old_reg_dir=$CS_PROCEVENT_CLAIM_REG_DIR
          old_token=$CS_PROCEVENT_CLAIM_TOKEN
          if [ -L "$old_reg_dir" ] || { [ -e "$old_reg_dir" ] && [ ! -d "$old_reg_dir" ]; }; then
            status=1
          else
            local stage="$old_reg_dir/.$id.$old_token.output"
            if { [ -e "$stage" ] || [ -L "$stage" ]; } && ! rm -f -- "$stage"; then
              status=1
            fi
          fi
          [ "$status" -ne 0 ] || rm -f -- "$claim" || status=1
        else
          status=1
        fi
        ;;
      *) status=1 ;;
    esac
    if [ "$status" -eq 0 ] && { [ ! -f "$registration" ] || [ -L "$registration" ]; }; then
      status=1
    fi
  fi
  [ "$status" -eq 0 ] || return "$status"
  tmp=$(umask 077; mktemp "$root/.claim.XXXXXX") || return 1
  token=${tmp##*/}-$pid
  if printf '%s\n%s\n%s\n%s\n%s\n%s\nactive\n' \
      "$home" "$pid" "$token" "$identity" "$reg_dir" "$reg_identity" > "$tmp" \
    && chmod 0600 "$tmp" \
    && mv -f -- "$tmp" "$claim"; then
    CS_PROCEVENT_CLAIM_TOKEN=$token
    CS_PROCEVENT_CLAIM_REG_IDENTITY=$reg_identity
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# Flip this exact generation to `terminal` so a concurrent reconcile treats the
# source as retiring instead of unowned while the runner finishes unregistering.
cs_procevent_claim_mark_terminal_locked() {  # <source-id> <home> <pid> <token>
  local id=$1 home=$2 pid=$3 token=$4 claim root tmp
  claim=$(cs_procevent_claim_path "$id")
  cs_procevent_claim_load_locked "$id" \
    && [ "$CS_PROCEVENT_CLAIM_HOME" = "$home" ] \
    && [ "$CS_PROCEVENT_CLAIM_PID" = "$pid" ] \
    && [ "$CS_PROCEVENT_CLAIM_TOKEN" = "$token" ] || return 1
  root=$(cs_procevent_claim_root)
  tmp=$(umask 077; mktemp "$root/.claim.XXXXXX") || return 1
  if printf '%s\n%s\n%s\n%s\n%s\n%s\nterminal\n' \
      "$CS_PROCEVENT_CLAIM_HOME" "$CS_PROCEVENT_CLAIM_PID" "$CS_PROCEVENT_CLAIM_TOKEN" \
      "$CS_PROCEVENT_CLAIM_IDENTITY" "$CS_PROCEVENT_CLAIM_REG_DIR" \
      "$CS_PROCEVENT_CLAIM_REG_IDENTITY" > "$tmp" \
    && chmod 0600 "$tmp" \
    && mv -f -- "$tmp" "$claim"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

cs_procevent_claim_release_locked() {  # <source-id> <home> <pid> <token>
  local id=$1 home=$2 pid=$3 token=$4 claim
  cs_procevent_source_id_valid "$id" || return 1
  claim=$(cs_procevent_claim_path "$id")
  [ -e "$claim" ] || return 0
  if cs_procevent_claim_load_locked "$id" \
    && [ "$CS_PROCEVENT_CLAIM_HOME" = "$home" ] \
    && [ "$CS_PROCEVENT_CLAIM_PID" = "$pid" ] \
    && [ "$CS_PROCEVENT_CLAIM_TOKEN" = "$token" ]; then
    rm -f -- "$claim"
    return $?
  fi
  return 1
}

# --- durable capture and publication ----------------------------------------

# cs_procevent_capture <state> <source-id> <adapter> <output-file>
# Atomically store the completed output at 0600 and print its durable path. The
# result rename is the COMMIT POINT: nothing referencing this result may be
# published before it returns successfully. The adapter-identity file is renamed
# first, so a result that exists is always readable as a complete record.
cs_procevent_capture() {
  local state=$1 id=$2 adapter=$3 src=$4 inbox seq dest tmp adapter_dest adapter_tmp
  cs_procevent_source_id_valid "$id" || return 1
  cs_procevent_adapter_valid "$adapter" || return 1
  inbox=$(cs_procevent_inbox_dir "$state")
  (umask 077; mkdir -p "$inbox") || return 1
  seq=1
  while [ -e "$inbox/$id.$seq.result" ]; do seq=$((seq + 1)); done
  dest="$inbox/$id.$seq.result"
  adapter_dest="$inbox/$id.$seq.adapter"
  tmp=$(umask 077; mktemp "$inbox/.capture.XXXXXX") || return 1
  adapter_tmp=$(umask 077; mktemp "$inbox/.adapter.XXXXXX") || { rm -f -- "$tmp"; return 1; }
  if ! cat "$src" > "$tmp" \
    || ! printf '%s\n' "$adapter" > "$adapter_tmp" \
    || ! chmod 0600 "$tmp" "$adapter_tmp" \
    || ! mv -f -- "$adapter_tmp" "$adapter_dest"; then
    rm -f -- "$tmp" "$adapter_tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp" "$adapter_dest"
    return 1
  fi
  printf '%s\n' "$dest"
}

# cs_procevent_pending <state>
# Every durably captured result with no durable handled acknowledgement yet,
# oldest first. A result stays here - and so stays eligible for re-announcement
# on the durable wake queue - across any number of drains and restarts until
# cs_procevent_mark_handled records it.
cs_procevent_pending() {
  local state=$1 inbox result base seq
  inbox=$(cs_procevent_inbox_dir "$state")
  [ -d "$inbox" ] || return 0
  for result in "$inbox"/*.result; do
    [ -f "$result" ] && [ ! -L "$result" ] || continue
    [ -e "${result%.result}.handled" ] && continue
    base=${result%.result}
    seq=${base##*.}
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    printf '%s\t%s\n' "$seq" "$result"
  done | sort -n -k1,1 -k2,2 | cut -f2-
}

# cs_procevent_event_line <adapter> <source-id> <sequence>
# The complete normalized event. Bounded by construction: a fixed verb, a
# validated adapter name, a validated id, and a number. No source output, path,
# or caller-supplied text can ever appear on a wake line.
cs_procevent_event_line() {
  local adapter=$1 id=$2 seq=$3
  cs_procevent_adapter_valid "$adapter" || return 1
  cs_procevent_source_id_valid "$id" || return 1
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  printf 'procevent %s %s %s\n' "$adapter" "$id" "$seq"
}

cs_procevent_handled_marker() {  # <state> <source-id> <sequence>
  printf '%s/%s.%s.handled\n' "$(cs_procevent_inbox_dir "$1")" "$2" "$3"
}

cs_procevent_is_handled() {  # <state> <source-id> <sequence>
  local marker; marker=$(cs_procevent_handled_marker "$1" "$2" "$3")
  [ -f "$marker" ] && [ ! -L "$marker" ]
}

# cs_procevent_mark_handled <state> <source-id> <sequence>
# The one durable acknowledgement per captured generation, keyed by the exact
# source id and sequence. The hardlink create is the atomic check-and-set, so
# two concurrent callers can never both win and a caller pairing this with an
# external effect can trust the reported distinction. It REFUSES unless the
# matching result and adapter records already exist, so a premature call cannot
# suppress a future result. This is the only terminal state: announcing a result
# never stops it being re-announced, only this does.
# 0 = newly recorded, 1 = already recorded (repeat), 2 = error.
cs_procevent_mark_handled() {
  local state=$1 id=$2 seq=$3 inbox result adapter_file marker tmp
  cs_procevent_source_id_valid "$id" || return 2
  case "$seq" in ''|*[!0-9]*) return 2 ;; esac
  inbox=$(cs_procevent_inbox_dir "$state")
  result="$inbox/$id.$seq.result"
  adapter_file="$inbox/$id.$seq.adapter"
  [ -f "$result" ] && [ ! -L "$result" ] || return 2
  [ -f "$adapter_file" ] && [ ! -L "$adapter_file" ] || return 2
  marker=$(cs_procevent_handled_marker "$state" "$id" "$seq")
  [ ! -L "$marker" ] || return 2
  tmp=$(umask 077; mktemp "$inbox/.handled.XXXXXX") || return 2
  if ! chmod 0600 "$tmp"; then
    rm -f -- "$tmp"
    return 2
  fi
  if ln "$tmp" "$marker" 2>/dev/null; then
    rm -f -- "$tmp"
    return 0
  fi
  rm -f -- "$tmp"
  [ -f "$marker" ] && [ ! -L "$marker" ] && return 1
  return 2
}

cs_procevent_result_source_id() {  # <result-path>
  local base=${1##*/}
  base=${base%.result}
  printf '%s\n' "${base%.*}"
}

cs_procevent_result_sequence() {  # <result-path>
  local base=${1##*/}
  base=${base%.result}
  printf '%s\n' "${base##*.}"
}

cs_procevent_result_adapter() {  # <result-path>
  local result=$1 adapter_file="${1%.result}.adapter" adapter extra
  [ -f "$result" ] && [ ! -L "$result" ] || return 1
  [ -f "$adapter_file" ] && [ ! -L "$adapter_file" ] || return 1
  {
    IFS= read -r adapter \
      && ! IFS= read -r extra
  } < "$adapter_file" || return 1
  [ -z "$extra" ] || return 1
  cs_procevent_adapter_valid "$adapter" || return 1
  printf '%s\n' "$adapter"
}
