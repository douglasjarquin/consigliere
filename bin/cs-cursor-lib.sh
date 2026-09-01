#!/usr/bin/env bash
# Cursor executable resolution and Cursor process identity.
# Sourced by bin/cs-spawn.sh, bin/cs-harness-lib.sh, and bin/cs-herdr-lib.sh.
# This file is sourced by scripts and has no side effects on source.
#
# Why one owner: cursor ships TWO executable names - `cursor-agent`, plus the
# legacy alias `agent` it installs on every platform. `agent` is far too
# generic to trust on its name alone, so every spawn, ancestry, and liveness
# caller has to agree on the same narrowed rule or an unrelated `/opt/agent`,
# an unrelated `agent` on PATH, or a path that merely contains an `agent/`
# directory component silently classifies as this harness. That widening would
# let consigliere launch an unrelated executable with Cursor flags.
#
# Two independent kinds of Cursor evidence are accepted, and either alone
# carries a positive verdict, so no single vendor string is load-bearing:
#
#   Structural (no subprocess, safe during a process scan): the canonical path
#   is named cursor-agent or lives under Cursor's versioned install tree.
#   Cursor's installer places both names as symlinks into
#   ~/.local/share/cursor-agent/versions/<version>/cursor-agent (verified
#   2026-09-01, cursor-agent at ~/.local/bin/cursor-agent), so the alias
#   resolves to Cursor's own name and install tree.
#
#   Probe (a bounded `--help` run, used only when resolving an executable to
#   launch, never during a process scan): Cursor's own CLI banner and its
#   CURSOR_API_ENDPOINT / api2.cursor.sh option text. Fails closed on a
#   timeout, a non-zero exit, or missing markers - a bare zero exit is never
#   accepted as proof.
#
# Process detection deliberately uses the structural signal only. Probing an
# arbitrary pid's executable during an ancestry walk or a liveness poll would
# execute a stranger's binary, which is exactly the hazard this file exists to
# close.
#
# Cursor's composer shape is deliberately NOT here. Its reverse-video
# placeholder remnant is taught to the ONE fleet-wide screen classifier in
# bin/cs-composer-lib.sh.

CS_CURSOR_PROBE_TIMEOUT=${CS_CURSOR_PROBE_TIMEOUT:-10}

cs_cursor_canonical_path() {  # <path>
  local path=$1 dir base
  [ -n "$path" ] || return 1
  dir=$(CDPATH='' cd -- "$(dirname -- "$path")" 2>/dev/null && pwd -P) || { printf '%s\n' "$path"; return 0; }
  base=$(basename -- "$path")
  local hops=0 target
  while [ -L "$dir/$base" ] && [ "$hops" -lt 16 ]; do
    target=$(readlink -- "$dir/$base") || break
    case "$target" in
      /*) dir=$(CDPATH='' cd -- "$(dirname -- "$target")" 2>/dev/null && pwd -P) || break
          base=$(basename -- "$target") ;;
      *)  dir=$(CDPATH='' cd -- "$dir/$(dirname -- "$target")" 2>/dev/null && pwd -P) || break
          base=$(basename -- "$target") ;;
    esac
    hops=$((hops + 1))
  done
  printf '%s\n' "$dir/$base"
}

cs_cursor_path_is_cursor() {  # <path>
  local path=$1 canonical
  [ -n "$path" ] || return 1
  canonical=$(cs_cursor_canonical_path "$path") || return 1
  case "${canonical##*/}" in cursor-agent) return 0 ;; esac
  case "$canonical" in */cursor-agent/versions/*/*) return 0 ;; esac
  return 1
}

cs_cursor_bounded_output() {  # <path> <args...>
  local path=$1 runner=
  shift
  [ -n "$path" ] && [ -x "$path" ] || return 1
  if command -v timeout >/dev/null 2>&1; then runner=timeout
  elif command -v gtimeout >/dev/null 2>&1; then runner=gtimeout
  fi
  [ -n "$runner" ] || return 1
  "$runner" "$CS_CURSOR_PROBE_TIMEOUT" "$path" "$@" 2>/dev/null
}

cs_cursor_probe_is_cursor() {  # <path>
  local path=$1 out
  out=$(cs_cursor_bounded_output "$path" --help) || return 1
  [ -n "$out" ] || return 1
  case "$out" in
    *"Start the Cursor Agent"*) return 0 ;;
    *CURSOR_API_ENDPOINT*) return 0 ;;
    *api2.cursor.sh*) return 0 ;;
  esac
  return 1
}

cs_cursor_verify_executable() {  # <path>
  local path=$1
  [ -n "$path" ] && [ -x "$path" ] || return 1
  case "${path##*/}" in cursor-agent) return 0 ;; esac
  cs_cursor_path_is_cursor "$path" && return 0
  cs_cursor_probe_is_cursor "$path"
}

cs_cursor_list_models() {  # <path>
  cs_cursor_bounded_output "$1" --list-models
}

cs_cursor_catalog_has_model() {  # <model>
  local wanted=$1
  awk -v wanted="$wanted" '
    BEGIN { ansi = sprintf("%c\\[[0-9;]*[A-Za-z]", 27) }
    {
      line = $0
      gsub(ansi, "", line)
      separator = index(line, " - ")
      if (!separator) next
      id = substr(line, 1, separator - 1)
      sub(/^[[:space:]]+/, "", id)
      sub(/[[:space:]]+$/, "", id)
      if (id == wanted) found = 1
    }
    END { exit found ? 0 : 1 }
  '
}

cs_cursor_resolve_binary() {
  local name candidate
  for name in cursor-agent agent; do
    candidate=$(command -v "$name" 2>/dev/null || true)
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if cs_cursor_verify_executable "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  for name in cursor-agent agent; do
    [ -n "${HOME:-}" ] || break
    candidate="$HOME/.local/bin/$name"
    [ -x "$candidate" ] || continue
    if cs_cursor_verify_executable "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  echo "error: no verified cursor executable found; searched PATH for 'cursor-agent' and 'agent', plus '${HOME:-}/.local/bin/cursor-agent' and '${HOME:-}/.local/bin/agent'. A file named 'agent' is accepted only when it resolves into Cursor's install tree or its --help identifies the Cursor Agent CLI." >&2
  return 1
}

cs_cursor_argv0_for_pid() {  # <pid> [comm-fallback]
  local pid=$1 fallback=${2:-} proc_root=${CS_PROC_ROOT_OVERRIDE:-/proc} argv0=
  if [ -r "$proc_root/$pid/cmdline" ]; then
    IFS= read -r -d '' argv0 < "$proc_root/$pid/cmdline" || true
    [ -n "$argv0" ] && { printf '%s\n' "$argv0"; return 0; }
  fi
  if [ -z "$fallback" ]; then
    fallback=$(LC_ALL=C ps -p "$pid" -o comm= 2>/dev/null || true)
  fi
  [ -n "$fallback" ] || return 1
  printf '%s\n' "$fallback"
}

cs_cursor_argv0_is_cursor() {  # <argv0>
  local argv0=$1
  [ -n "$argv0" ] || return 1
  case "$argv0" in
    ''|MainThread) return 1 ;;
    cursor-agent) return 0 ;;
  esac
  cs_cursor_path_is_cursor "$argv0"
}

cs_cursor_process_matches() {  # <comm> <args> [argv0]
  local comm=$1 argv0=${3:-} base
  [ -n "$comm" ] || [ -n "$argv0" ] || return 1
  argv0=${argv0:-$comm}
  base=$(basename -- "$comm")
  base=${base#-}
  case "$base" in
    cursor-agent) return 0 ;;
    agent|MainThread|node|node-*|node[0-9]*|python|python[0-9]*|python[0-9].[0-9]*)
      cs_cursor_argv0_is_cursor "$argv0" && return 0
      cs_cursor_path_is_cursor "$comm" && return 0
      return 1
      ;;
  esac
  case "$comm" in */*) cs_cursor_path_is_cursor "$comm" && return 0 ;; esac
  return 1
}

# cs_cursor_write_session_sidecar <state-dir> <task-id> <abs-worktree>
# Bind a cursor soldier to its conversation transcript fold source.
cs_cursor_write_session_sidecar() {
  local state=$1 id=$2 wt=$3
  local projects_root="${CURSOR_PROJECTS_ROOT_OVERRIDE:-$HOME/.cursor/projects}"
  {
    printf 'projects_root=%s\n' "$projects_root"
    printf 'workspace_root=%s\n' "$wt"
  } > "$state/$id.cursor-session"
}
