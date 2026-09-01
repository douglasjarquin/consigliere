#!/usr/bin/env bash
# cs-meta-lib.sh - state/<id>.meta read/write helpers. Sourced, never executed.
#
# Meta files are flat key=value lines written by cs-spawn.sh and appended by
# cs-pr-check.sh. docs/configuration.md owns the field inventory. Values never
# contain newlines; the LAST occurrence of a key wins so appends supersede
# without rewriting history.

cs_meta_path() { # <state-dir> <id>
  printf '%s/%s.meta' "$1" "$2"
}

cs_meta_get() { # <meta-file> <key> -> value or rc=1
  local file=$1 key=$2 val
  [ -f "$file" ] || return 1
  val=$(awk -F= -v k="$key" '$1==k { v=substr($0, length(k)+2) } END { if (v != "") print v }' "$file")
  [ -n "$val" ] || return 1
  printf '%s\n' "$val"
}

cs_meta_set() { # <meta-file> <key> <value>  - append; last occurrence wins
  printf '%s=%s\n' "$2" "$3" >> "$1"
}

cs_meta_write() { # <meta-file> <key=val>...  - atomic full write
  local file=$1 tmp kv
  shift
  tmp="$file.tmp.$$"
  : > "$tmp"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$tmp"
  done
  mv "$tmp" "$file"
}

cs_meta_list_ids() { # <state-dir> -> task ids with meta files, one per line
  local dir=$1 f
  for f in "$dir"/*.meta; do
    [ -e "$f" ] || continue
    basename "$f" .meta
  done
}

cs_meta_validate_parent_values() {
  local parent_task=$1 parent_home=$2 parent_state=$3 parent_pane=$4
  local parent_generation=$5 endpoint_generation=$6
  case "$parent_task" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$parent_home" in /*) ;; *) return 1 ;; esac
  case "$parent_state" in "$parent_home/state") ;; *) return 1 ;; esac
  [ -d "$parent_home" ] && [ -d "$parent_state" ] || return 1
  case "$parent_pane" in w[[:alnum:]_-]*:p[[:alnum:]_-]*) ;; unknown) ;; *) return 1 ;; esac
  case "$parent_generation" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  case "$endpoint_generation" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
}

cs_meta_validate_parent_edge() {
  local meta=$1
  [ -f "$meta" ] || return 1
  cs_meta_validate_parent_values \
    "$(cs_meta_get "$meta" parent_task_id 2>/dev/null || true)" \
    "$(cs_meta_get "$meta" parent_home 2>/dev/null || true)" \
    "$(cs_meta_get "$meta" parent_state 2>/dev/null || true)" \
    "$(cs_meta_get "$meta" parent_pane 2>/dev/null || true)" \
    "$(cs_meta_get "$meta" parent_generation 2>/dev/null || true)" \
    "$(cs_meta_get "$meta" endpoint_generation 2>/dev/null || true)"
}

cs_meta_endpoint_generation_known() {
  local meta=$1 generation=$2 current previous
  current=$(cs_meta_get "$meta" endpoint_generation 2>/dev/null || true)
  [ "$current" = "$generation" ] && return 0
  while IFS= read -r previous; do
    [ "$previous" = "$generation" ] && return 0
  done < <(awk -F= '$1 == "previous_endpoint_generation" { print substr($0, 30) }' "$meta")
  return 1
}

cs_meta_event_route() {
  local state=$1 pane=$2 workspace=$3 agent=$4 meta id found=''
  [ -d "$state" ] || return 1
  [ -n "$pane" ] || return 1
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(cs_meta_get "$meta" pane 2>/dev/null || true)" = "$pane" ] || continue
    [ -z "$found" ] || return 1
    found=$meta
  done
  [ -n "$found" ] || return 1
  if [ -n "$workspace" ] && [ "$(cs_meta_get "$found" workspace 2>/dev/null || true)" != "$workspace" ]; then
    return 1
  fi
  if [ -n "$agent" ] && [ "$(cs_meta_get "$found" harness 2>/dev/null || true)" != "$agent" ]; then
    return 1
  fi
  cs_meta_validate_parent_edge "$found" || return 1
  id=$(basename "$found" .meta)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$id" \
    "$(cs_meta_get "$found" parent_task_id)" \
    "$(cs_meta_get "$found" parent_home)" \
    "$(cs_meta_get "$found" parent_state)" \
    "$(cs_meta_get "$found" parent_pane)" \
    "$(cs_meta_get "$found" parent_generation)" \
    "$(cs_meta_get "$found" endpoint_generation)"
}
