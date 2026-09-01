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
