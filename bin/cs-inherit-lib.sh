#!/usr/bin/env bash
# cs-inherit-lib.sh - the deliberately tiny capo inheritance surface.
#
# Exactly two items flow from the main consigliere home into a capo home,
# and nothing ever flows back:
#   - data/boss-shared.md   main-authoritative shared boss preferences,
#                           propagated as a READ-ONLY copy (mode 444) with a
#                           generated do-not-edit header prepended, converged
#                           at seed time and on every bootstrap sweep;
#   - config/backlog-backend  the backlog backend choice, copied once at seed
#                           time only (a capo may later diverge deliberately).
#
# Convergence discipline (ported from firstmate's config-inherit machinery,
# minus its multi-harness config allowlist): the main copy is authoritative.
# The capo copy is rewritten ONLY when it no longer matches what the main copy
# renders to - an unchanged main copy with an unchanged capo copy is a no-op
# that never churns bytes or mtimes. A divergent capo copy (local edit, which
# the read-only mode discourages but cannot prevent) is quarantined to a dated
# private sibling before being replaced, and the replacement is reported as a
# "CAPO_SYNC:" line so drift is visible instead of silently discarded. When
# the main copy is absent, an existing capo copy is quarantined too, so
# absence converges. Nothing in this library ever reads a capo copy back into
# the main home.
#
# Sourced by bin/cs-home-seed.sh and the tests. No side effects on source.
# set -u / set -e safe. Functions return non-zero only on a real propagation
# error; quarantined drift is a success with a CAPO_SYNC line.

CS_SHARED_BOSS_FILE="boss-shared.md"
CS_SHARED_BOSS_REL="data/$CS_SHARED_BOSS_FILE"
CS_SHARED_BOSS_MODE=444

# The do-not-edit note prepended to every propagated capo copy. Comparing the
# RENDERED bytes (header + main content) against the capo copy is what makes
# convergence idempotent without requiring the boss to maintain a magic header
# in the main file itself.
cs_inherit_shared_boss_header() {
  cat <<'EOF'
<!-- READ-ONLY COPY - DO NOT EDIT.
     Propagated from the main consigliere home's data/boss-shared.md, which is
     the authoritative copy. Route new shared boss preferences to the main
     consigliere through a marked status reply or a document pointer; edits
     made here are quarantined and overwritten on the next convergence. -->
EOF
}

_cs_inherit_ordinary_file() {  # <path> - 0 if a plain non-symlink regular file
  [ -f "$1" ] && [ ! -L "$1" ]
}

_cs_inherit_dir_safe() {  # <dir> - existing (or creatable) non-symlink dir
  local dir=$1
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ]
    return $?
  fi
  mkdir -p "$dir" 2>/dev/null || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ]
}

# Render the expected capo-copy bytes (header + blank line + main content).
_cs_inherit_render_shared_boss() {  # <src> <out-file>
  {
    cs_inherit_shared_boss_header
    printf '\n'
    cat "$1"
  } > "$2"
}

_cs_inherit_quarantine_name() {  # <parent> <base> -> unique dated sibling path
  local parent=$1 base=$2 stamp candidate n=0
  stamp=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null) || return 1
  candidate="$parent/.$base.quarantine.$stamp"
  while [ -e "$candidate" ] || [ -L "$candidate" ]; do
    n=$((n + 1))
    candidate="$parent/.$base.quarantine.$stamp.$n"
  done
  printf '%s\n' "$candidate"
}

# Move a divergent capo copy aside. Prints the quarantine artifact path.
_cs_inherit_quarantine_dest() {  # <dest>
  local dest=$1 parent artifact
  _cs_inherit_ordinary_file "$dest" || return 1
  parent=$(dirname "$dest")
  artifact=$(_cs_inherit_quarantine_name "$parent" "$(basename "$dest")") || return 1
  chmod u+w "$dest" 2>/dev/null || return 1
  mv -- "$dest" "$artifact" 2>/dev/null || return 1
  chmod 0600 "$artifact" 2>/dev/null || true
  printf '%s\n' "$artifact"
}

# cs_inherit_shared_boss <src-data-dir> <dest-data-dir> [capo-home-label]
# Converge the capo's read-only data/boss-shared.md copy to the main home's.
# Emits CAPO_SYNC: lines to stdout when local drift is quarantined; silent on
# unchanged and on a clean push. Returns 1 on a real propagation error.
cs_inherit_shared_boss() {
  local src_data=$1 dest_data=$2 label=${3:-}
  local src dest tmp artifact
  [ -n "$src_data" ] && [ -n "$dest_data" ] || return 1
  src="$src_data/$CS_SHARED_BOSS_FILE"
  dest="$dest_data/$CS_SHARED_BOSS_FILE"
  [ -n "$label" ] || label=${dest_data%/data}

  if [ -e "$src" ] || [ -L "$src" ]; then
    _cs_inherit_ordinary_file "$src" || {
      echo "cs-inherit: error: unsafe main source $src (symlink or not a regular file)" >&2
      return 1
    }
    _cs_inherit_dir_safe "$dest_data" || {
      echo "cs-inherit: error: unsafe destination directory $dest_data" >&2
      return 1
    }
    tmp=$(mktemp "$dest_data/.cs-boss-shared.XXXXXX" 2>/dev/null) || return 1
    if ! _cs_inherit_render_shared_boss "$src" "$tmp"; then
      rm -f "$tmp" 2>/dev/null || true
      return 1
    fi
    chmod 0600 "$tmp" 2>/dev/null || true
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      if ! _cs_inherit_ordinary_file "$dest"; then
        rm -f "$tmp" 2>/dev/null || true
        echo "cs-inherit: error: unsafe destination $dest (symlink or not a regular file)" >&2
        return 1
      fi
      if cmp -s "$tmp" "$dest"; then
        # Converged already; just re-assert the read-only mode.
        rm -f "$tmp" 2>/dev/null || true
        chmod "$CS_SHARED_BOSS_MODE" "$dest" 2>/dev/null || return 1
        return 0
      fi
      if ! artifact=$(_cs_inherit_quarantine_dest "$dest"); then
        rm -f "$tmp" 2>/dev/null || true
        echo "cs-inherit: error: failed to quarantine divergent $dest" >&2
        return 1
      fi
      printf 'CAPO_SYNC: capo home %s: quarantined %s drift at %s\n' "$label" "$CS_SHARED_BOSS_REL" "$artifact"
    fi
    if ! mv -f -- "$tmp" "$dest" 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null || true
      echo "cs-inherit: error: failed to write $dest" >&2
      return 1
    fi
    chmod "$CS_SHARED_BOSS_MODE" "$dest" 2>/dev/null || return 1
    return 0
  fi

  # Main copy absent: mirror the absence downstream (quarantine, never rm).
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    _cs_inherit_ordinary_file "$dest" || {
      echo "cs-inherit: error: unsafe destination $dest (symlink or not a regular file)" >&2
      return 1
    }
    if ! artifact=$(_cs_inherit_quarantine_dest "$dest"); then
      echo "cs-inherit: error: failed to quarantine $dest before mirroring main absence" >&2
      return 1
    fi
    printf 'CAPO_SYNC: capo home %s: quarantined %s drift at %s (main copy absent)\n' "$label" "$CS_SHARED_BOSS_REL" "$artifact"
  fi
  return 0
}

# cs_inherit_backlog_backend <src-config-dir> <dest-config-dir>
# Seed-time copy of the backlog backend choice. Copies the main value when
# present; mirrors absence by removing a stale destination copy. Not run by
# the convergence sweep - a capo may later diverge deliberately.
cs_inherit_backlog_backend() {
  local src_config=$1 dest_config=$2 src dest tmp
  [ -n "$src_config" ] && [ -n "$dest_config" ] || return 1
  src="$src_config/backlog-backend"
  dest="$dest_config/backlog-backend"
  if [ -e "$src" ] || [ -L "$src" ]; then
    _cs_inherit_ordinary_file "$src" || {
      echo "cs-inherit: error: unsafe main source $src (symlink or not a regular file)" >&2
      return 1
    }
    _cs_inherit_dir_safe "$dest_config" || {
      echo "cs-inherit: error: unsafe destination directory $dest_config" >&2
      return 1
    }
    if [ -L "$dest" ]; then
      echo "cs-inherit: error: unsafe destination $dest (symlink)" >&2
      return 1
    fi
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
      return 0
    fi
    tmp=$(mktemp "$dest_config/.cs-backlog-backend.XXXXXX" 2>/dev/null) || return 1
    if ! cp "$src" "$tmp" 2>/dev/null || ! mv -f -- "$tmp" "$dest" 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null || true
      echo "cs-inherit: error: failed to write $dest" >&2
      return 1
    fi
    return 0
  fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    rm -f -- "$dest" 2>/dev/null || {
      echo "cs-inherit: error: failed to remove $dest while mirroring main absence" >&2
      return 1
    }
  fi
  return 0
}

# cs_inherit_seed <main-home> <capo-home> [label]
# The complete seed-time inheritance: shared boss preferences plus the
# backlog-backend copy.
cs_inherit_seed() {
  local main_home=$1 capo_home=$2 label=${3:-} rc=0
  cs_inherit_shared_boss "$main_home/data" "$capo_home/data" "$label" || rc=1
  cs_inherit_backlog_backend "$main_home/config" "$capo_home/config" || rc=1
  return "$rc"
}

# cs_inherit_converge <main-home> <capo-home> [label]
# The sweep-time convergence: shared boss preferences only.
cs_inherit_converge() {
  local main_home=$1 capo_home=$2 label=${3:-}
  cs_inherit_shared_boss "$main_home/data" "$capo_home/data" "$label"
}
