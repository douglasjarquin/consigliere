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

CS_META_ERROR=

cs_meta_canonical_existing() {
  LC_ALL=C perl -MCwd=realpath -e '
    my $resolved = realpath($ARGV[0]);
    exit 1 unless defined $resolved;
    print $resolved;
  ' "$1" 2>/dev/null
}

cs_meta_record_parent_authorized() {
  local path=$1 label=$2 root=$3 parent base parent_resolved expected_path
  local path_resolved root_resolved final_matches=1
  parent=${path%/*}
  [ "$parent" != "$path" ] || parent=.
  base=${path##*/}
  root_resolved=$(cs_meta_canonical_existing "$root") || {
    CS_META_ERROR="$label authorized directory cannot be resolved at $root"
    return 1
  }
  [ -d "$root_resolved" ] || {
    CS_META_ERROR="$label authorized directory is not a directory at $root"
    return 1
  }
  parent_resolved=$(cs_meta_canonical_existing "$parent") || {
    CS_META_ERROR="$label parent directory cannot be resolved at $path"
    return 1
  }
  expected_path=${parent_resolved%/}/$base
  if [ -e "$path" ] || [ -L "$path" ]; then
    path_resolved=$(cs_meta_canonical_existing "$path") || {
      CS_META_ERROR="$label cannot be resolved at $path"
      return 1
    }
    [ "$path_resolved" = "$expected_path" ] || final_matches=0
  else
    path_resolved=$expected_path
  fi
  case "$path_resolved" in
    "$root_resolved"/*) ;;
    *)
      CS_META_ERROR="$label resolves outside its authorized directory at $path"
      return 1
      ;;
  esac
  if [ "$final_matches" != 1 ]; then
    CS_META_ERROR="$label resolves through a different final path at $path"
    return 1
  fi
}

cs_meta_record_present() {
  local path=$1 label=${2:-record} root=$3
  cs_meta_record_parent_authorized "$path" "$label" "$root" || return 1
  if [ ! -f "$path" ]; then
    CS_META_ERROR="$label is not a regular file at $path"
    return 1
  fi
  return 0
}

cs_meta_publish_contained() {
  local source=$1 target=$2 label=${3:-record} root=$4
  cs_meta_record_present "$source" "$label staged record" "$root" || return 1
  cs_meta_record_parent_authorized "$target" "$label target" "$root" || return 1
  if [ -e "$target" ] || [ -L "$target" ]; then
    cs_meta_record_present "$target" "$label target" "$root" || return 1
  fi
  if ! mv -f "$source" "$target" 2>/dev/null || ! cs_meta_record_present "$target" "$label" "$root"; then
    [ -n "$CS_META_ERROR" ] \
      || CS_META_ERROR="$label publication failed at $target"
    return 1
  fi
  return 0
}

cs_meta_write() { # <meta-file> <key=val>...  - atomic full write
  local file=$1 tmp kv root
  shift
  root=${file%/*}
  tmp="$file.tmp.$$"
  : > "$tmp"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$tmp"
  done
  cs_meta_publish_contained "$tmp" "$file" "task record" "$root" || {
    rm -f "$tmp"
    return 1
  }
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

cs_meta_validate_herdr_session() {
  case "${1:-}" in
    [A-Za-z0-9._-][A-Za-z0-9._-]*) return 0 ;;
    *) return 1 ;;
  esac
}

cs_meta_validate_parent_edge() {
  local meta=$1 child_home parent_home parent_session
  [ -f "$meta" ] || return 1
  cs_meta_validate_parent_values \
    "$(cs_meta_get "$meta" parent_task_id 2>/dev/null || true)" \
    "$(cs_meta_get "$meta" parent_home 2>/dev/null || true)" \
    "$(cs_meta_get "$meta" parent_state 2>/dev/null || true)" \
    "$(cs_meta_get "$meta" parent_pane 2>/dev/null || true)" \
    "$(cs_meta_get "$meta" parent_generation 2>/dev/null || true)" \
    "$(cs_meta_get "$meta" endpoint_generation 2>/dev/null || true)" || return 1
  child_home=$(cs_meta_get "$meta" home 2>/dev/null || true)
  parent_home=$(cs_meta_get "$meta" parent_home 2>/dev/null || true)
  parent_session=$(cs_meta_get "$meta" parent_herdr_session 2>/dev/null || true)
  if [ -n "$parent_session" ]; then
    cs_meta_validate_herdr_session "$parent_session" || return 1
  elif [ -n "$child_home" ] && [ "$child_home" != "$parent_home" ]; then
    return 1
  fi
}

cs_meta_endpoint_generation_known() {
  local meta=$1 generation=$2 created_at=${3:-} current previous previous_at
  current=$(cs_meta_get "$meta" endpoint_generation 2>/dev/null || true)
  [ "$current" = "$generation" ] && return 0
  case "$created_at" in ''|*[!0-9]*) return 1 ;; esac
  while IFS=$'\t' read -r previous previous_at; do
    [ "$previous" = "$generation" ] || continue
    case "$previous_at" in ''|*[!0-9]*) continue ;; esac
    [ "$created_at" -le "$previous_at" ] && return 0
  done < <(awk -F= '
    $1 == "previous_endpoint_generation" { previous=substr($0, 30); next }
    $1 == "previous_endpoint_generation_at" && previous != "" {
      print previous "\t" substr($0, 33); previous=""
    }
  ' "$meta")
  return 1
}

cs_meta_endpoint_generation_rotation_lines() { # <existing-meta-file-or-empty> <new-generation>
  # -> key=value lines for a cs_meta_write (full-overwrite) call site to fold
  # in, carrying forward every previous_endpoint_generation/_at pair already
  # on file plus the just-superseded current generation. Each pair must stay
  # adjacent: cs_meta_endpoint_generation_known's reader pairs a
  # previous_endpoint_generation line with only the very next
  # previous_endpoint_generation_at line, silently dropping an unpaired one.
  local existing=$1 new=$2 current previous previous_at
  if [ -n "$existing" ] && [ -f "$existing" ]; then
    while IFS=$'\t' read -r previous previous_at; do
      printf 'previous_endpoint_generation=%s\n' "$previous"
      printf 'previous_endpoint_generation_at=%s\n' "$previous_at"
    done < <(awk -F= '
      $1 == "previous_endpoint_generation" { previous=substr($0, 30); next }
      $1 == "previous_endpoint_generation_at" && previous != "" {
        print previous "\t" substr($0, 33); previous=""
      }
    ' "$existing")
    current=$(cs_meta_get "$existing" endpoint_generation 2>/dev/null || true)
    if [ -n "$current" ]; then
      printf 'previous_endpoint_generation=%s\n' "$current"
      printf 'previous_endpoint_generation_at=%s\n' "$(date +%s)"
    fi
  fi
  printf 'endpoint_generation=%s\n' "$new"
}

# home= is written only for capos (cs-spawn.sh's capo-spawn branch); an
# ordinary task's effective home is its own recorded parent_home. Callers
# already wrap this in `|| true` and compare a non-empty value, so an absent
# home AND parent_home correctly degrades to reject, not to a silent pass.
cs_meta_home() { # <meta-file> -> the task's own home, defaulting to its parent's
  local meta=$1 home
  home=$(cs_meta_get "$meta" home 2>/dev/null || true)
  [ -n "$home" ] && { printf '%s\n' "$home"; return 0; }
  cs_meta_get "$meta" parent_home
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
