#!/usr/bin/env bash
# The herdr event spool: the durable transport between herdr's server-side
# plugin `[[events]]` hook and this home's watcher.
#
# SHAPE. herdr runs bin/cs-herdr-event-hook.sh once per subscribed event, in the
# server's own process tree, whether or not any consigliere process is running.
# The hook appends ONE line per event to <state>/.herdr-events; the watcher
# drains that file from a persisted byte cursor. Nothing streams, nothing
# reconnects, and an edge that fires while the watcher is down is still waiting
# in the file when it starts.
#
# LINE FORMAT (identical to the projection the watcher already parses):
#     <kind>\t<pane_id>\t<workspace_id>\t<field3>\t<field4>
# Field 1 is the event kind, so a consumer never infers which subscription
# produced a line and an unknown kind is ignored rather than misread. For the
# one kind this transport carries, `status` (pane.agent_status_changed), field3
# is the agent status and field4 the agent name.
#
# WHY A FILE AND NOT A FIFO. The point of moving onto plugin hooks is that the
# producer outlives every consumer: a fifo would drop every edge with no reader
# attached, which is exactly the watcher-restart gap this replaces.
#
# DURABILITY LIMITS, both covered by the watcher's level reconcile on start:
# the spool is truncated when it passes CS_EVENT_SPOOL_MAX_BYTES, and events
# that fire while the plugin is uninstalled are never written at all.

CS_EVENT_SPOOL_MAX_BYTES=${CS_EVENT_SPOOL_MAX_BYTES:-262144}

cs_event_spool_path() {  # <state_dir>
  printf '%s/.herdr-events' "$1"
}

cs_event_cursor_path() {  # <state_dir>
  printf '%s/.herdr-events-cursor' "$1"
}

cs_event_file_size() {  # <path>
  local size
  if [ "$(uname)" = Darwin ]; then
    size=$(LC_ALL=C stat -f %z "$1" 2>/dev/null)
  else
    size=$(LC_ALL=C stat -c %s "$1" 2>/dev/null)
  fi
  case "${size:-}" in
    ''|*[!0-9]*) printf '0'; return 1 ;;
  esac
  printf '%s' "$size"
}

# Build one record from up to five fields, flattening each to a single tab-free
# token. Every substitution is parameter expansion and the fields are joined in
# place: this runs inside herdr's hook for every status edge of every pane on
# the machine, and a command substitution per field would fork a subshell each
# time for work bash does natively. Missing trailing fields are emitted empty,
# so a record is always exactly five fields.
cs_event_record() {  # <kind> <pane_id> <workspace_id> <field3> <field4>
  local out='' n=0 field
  for field in "$@"; do
    [ "$n" -lt 5 ] || break
    field=${field//$'\t'/ }
    field=${field//$'\r'/ }
    field=${field//$'\n'/ }
    if [ "$n" -eq 0 ]; then out=$field; else out=$out$'\t'$field; fi
    n=$((n + 1))
  done
  while [ "$n" -lt 5 ]; do
    out=$out$'\t'
    n=$((n + 1))
  done
  printf '%s' "$out"
}

# One record, one `printf` to an O_APPEND descriptor: well under PIPE_BUF, so
# concurrent hooks for different panes interleave whole lines and never a
# half-written one. The drain relies on that (it consumes only up to the last
# newline in the file).
cs_event_append() {  # <spool> <record>
  local spool=$1 record=$2 size
  [ -n "$record" ] || return 1
  mkdir -p "$(dirname "$spool")" 2>/dev/null || return 1
  if size=$(cs_event_file_size "$spool") && [ "$size" -gt "$CS_EVENT_SPOOL_MAX_BYTES" ]; then
    : > "$spool" 2>/dev/null || return 1
  fi
  printf '%s\n' "$record" >> "$spool" 2>/dev/null || return 1
}

# Print every complete record appended since the last drain and advance the
# cursor past them. rc 1 means nothing new (including an absent spool), so a
# caller can treat "no news" and "no transport" the same way and keep polling.
#
# A cursor beyond the file's end means the spool was rotated under us, so it
# restarts from the beginning rather than going permanently silent. A trailing
# partial line (a hook killed mid-write) is left unconsumed for the next drain
# instead of being handed on as a truncated record.
cs_event_drain() {  # <spool> <cursor_file>
  local spool=$1 cursor_file=$2 size cursor chunk
  size=$(cs_event_file_size "$spool") || return 1
  cursor=$(cat "$cursor_file" 2>/dev/null) || cursor=0
  case "$cursor" in
    ''|*[!0-9]*) cursor=0 ;;
  esac
  [ "$size" -lt "$cursor" ] && cursor=0
  [ "$size" -gt "$cursor" ] || return 1
  [ -z "$(LC_ALL=C tail -c 1 "$spool" 2>/dev/null)" ] || return 1
  chunk=$(LC_ALL=C tail -c "+$((cursor + 1))" "$spool" 2>/dev/null) || return 1
  [ -n "$chunk" ] || return 1
  printf '%s\n' "$size" > "$cursor_file.tmp" 2>/dev/null || return 1
  mv -f "$cursor_file.tmp" "$cursor_file" 2>/dev/null || return 1
  printf '%s\n' "$chunk"
}
