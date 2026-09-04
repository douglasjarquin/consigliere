#!/usr/bin/env bash
# cs-context-pack-lib.sh - closed-set validation and the component table for
# bin/cs-context-pack.sh. Sourced, never executed. Split out from the
# executable so tests/cs-context-pack.test.sh can call these functions
# directly instead of only through the full CLI.

if [ -n "${CS_CONTEXT_PACK_LIB_SOURCED:-}" ]; then
  return 0
fi
CS_CONTEXT_PACK_LIB_SOURCED=1

CS_CONTEXT_PACK_MAX_COMPONENT_BYTES=${CS_CONTEXT_PACK_MAX_COMPONENT_BYTES:-300000}

cs_pack_realpath() { # <path> -> fully symlink-resolved absolute path, or rc 1
  local path=$1 resolved
  resolved=$(perl -MCwd=realpath -e 'defined($p=realpath($ARGV[0])) or exit 1; print "$p\n"' "$path" 2>/dev/null) \
    && [ -n "$resolved" ] || return 1
  printf '%s\n' "$resolved"
}

cs_pack_sha256_of() { # <file> -> sha256 hex on stdout, or empty + rc 1
  local file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# cs_pack_resolve_component <cs-root> <path-relative-to-cs-root> -> absolute
# canonical path on stdout, or a diagnostic on stderr and rc 1. Rejects a
# missing file, a resolved path outside <cs-root> (traversal or a symlink
# escaping it), and a file over CS_CONTEXT_PACK_MAX_COMPONENT_BYTES. The one
# place fail-closed component-source validation lives.
cs_pack_resolve_component() {
  local root=$1 rel=$2 candidate resolved size
  root=$(cs_pack_realpath "$root") || {
    echo "error: CS_ROOT unresolvable: $1" >&2
    return 1
  }
  candidate="$root/$rel"
  if [ ! -e "$candidate" ]; then
    echo "error: component source missing: $rel" >&2
    return 1
  fi
  resolved=$(cs_pack_realpath "$candidate") || {
    echo "error: component source unresolvable: $rel" >&2
    return 1
  }
  case "$resolved" in
    "$root"/*) : ;;
    *)
      echo "error: component source escapes CS_ROOT (traversal or symlink): $rel -> $resolved" >&2
      return 1
      ;;
  esac
  [ -f "$resolved" ] || { echo "error: component source is not a regular file: $rel" >&2; return 1; }
  size=$(wc -c < "$resolved" | tr -d '[:space:]')
  if [ "$size" -gt "$CS_CONTEXT_PACK_MAX_COMPONENT_BYTES" ]; then
    echo "error: component source oversized: $rel is $size bytes, cap is $CS_CONTEXT_PACK_MAX_COMPONENT_BYTES" >&2
    return 1
  fi
  printf '%s\n' "$resolved"
}

cs_pack_workflow_valid() { # <role> <workflow> -> 0 iff workflow belongs to role's closed set
  local role=$1 workflow=$2
  case "$role" in
    root|capo) [ "$workflow" = none ] ;;
    scout) [ "$workflow" = report-only ] ;;
    ship) cs_delivery_mode_valid "$workflow" ;;
    *) return 1 ;;
  esac
}

# cs_pack_components_for_role <role> -> one "<id> <path-relative-to-CS_ROOT>"
# line per component on stdout. root's pack is the kernel prose itself, so it
# gets only the kernel plus the harness-fact library; every other role's
# pack is rendered by cs-brief.sh, so it gets the exact set of scripts that
# deterministically render it.
cs_pack_components_for_role() {
  case "$1" in
    root)
      printf 'kernel AGENTS.md\n'
      printf 'harness-facts bin/cs-harness-lib.sh\n'
      ;;
    scout|ship|capo)
      printf 'brief-generator bin/cs-brief.sh\n'
      printf 'delivery-lib bin/cs-delivery-lib.sh\n'
      printf 'dod-lib bin/cs-dod-lib.sh\n'
      printf 'harness-lib bin/cs-harness-lib.sh\n'
      printf 'exec-mode-lib bin/cs-exec-mode-lib.sh\n'
      ;;
    *)
      return 1
      ;;
  esac
}
