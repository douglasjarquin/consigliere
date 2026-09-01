# shellcheck shell=bash
# cs-grok-lib.sh - Grok Build executable resolution, process identity, and
# soldier turn-end wiring.
#
# Grok ships two executable names: `grok`, and the legacy alias `agent`. `agent`
# is far too generic to trust on its name alone, so every spawn, ancestry, and
# liveness caller agrees on the same narrowed rule.
#
# Turn-end uses a single global Stop hook under ${GROK_HOME:-~/.grok}/hooks/
# (always trusted, unlike project hooks) that is a guarded no-op unless the
# workspace holds a `.cs-grok-turnend` pointer matching the consigliere-owned
# registry. docs/grok.md owns the verified launch and hook facts.

CS_GROK_PROBE_TIMEOUT=${CS_GROK_PROBE_TIMEOUT:-10}

cs_grok_shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# cs_grok_home - the active Grok config/data root.
cs_grok_home() {
  if [ -n "${GROK_HOME:-}" ]; then
    printf '%s\n' "$GROK_HOME"
  else
    printf '%s/.grok\n' "$HOME"
  fi
}

# cs_grok_canonical_path <path> - absolute path with symlinks resolved.
cs_grok_canonical_path() {
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

# cs_grok_path_is_grok <path> - true when canonical evidence names Grok Build.
cs_grok_path_is_grok() {
  local path=$1 canonical base home
  [ -n "$path" ] || return 1
  canonical=$(cs_grok_canonical_path "$path") || return 1
  base=${canonical##*/}
  case "$base" in grok|agent) ;;
  *) return 1 ;;
  esac
  home=$(cs_grok_home)
  case "$canonical" in
    "$home"/bin/grok|"$home"/bin/agent) return 0 ;;
  esac
  case "$canonical" in
    */.grok/bin/grok|*/.grok/bin/agent) return 0 ;;
  esac
  return 1
}

cs_grok_bounded_output() {
  local path=$1 runner=
  shift
  [ -n "$path" ] && [ -x "$path" ] || return 1
  if command -v timeout >/dev/null 2>&1; then runner=timeout
  elif command -v gtimeout >/dev/null 2>&1; then runner=gtimeout
  fi
  [ -n "$runner" ] || return 1
  "$runner" "$CS_GROK_PROBE_TIMEOUT" "$path" "$@" 2>/dev/null
}

# cs_grok_probe_is_grok <path> - bounded --help identifies Grok Build.
cs_grok_probe_is_grok() {
  local path=$1 out
  out=$(cs_grok_bounded_output "$path" --help) || return 1
  [ -n "$out" ] || return 1
  case "$out" in
    *'Grok Build'*) return 0 ;;
  esac
  return 1
}

# cs_grok_verify_executable <path> - true when $1 may be launched as grok.
cs_grok_verify_executable() {
  local path=$1
  [ -n "$path" ] && [ -x "$path" ] || return 1
  case "${path##*/}" in
    grok) return 0 ;;
  esac
  cs_grok_path_is_grok "$path" && return 0
  cs_grok_probe_is_grok "$path"
}

# cs_grok_resolve_binary - print a stable launcher path, or refuse.
cs_grok_resolve_binary() {
  local name candidate home
  for name in grok agent; do
    candidate=$(command -v "$name" 2>/dev/null || true)
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if cs_grok_verify_executable "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  home=$(cs_grok_home)
  for name in grok agent; do
    candidate="$home/bin/$name"
    [ -x "$candidate" ] || continue
    if cs_grok_verify_executable "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  printf 'cs-grok: no verified grok executable found; searched PATH for grok and agent, plus %s/bin/grok and %s/bin/agent\n' \
    "$home" "$home" >&2
  return 1
}

cs_grok_argv0_for_pid() {
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

cs_grok_argv0_is_grok() {
  local argv0=$1
  [ -n "$argv0" ] || return 1
  case "$argv0" in
    ''|MainThread) return 1 ;;
    grok|agent) return 0 ;;
  esac
  cs_grok_path_is_grok "$argv0"
}

# cs_grok_process_matches <comm> <args> [argv0] - Grok process identity.
cs_grok_process_matches() {
  local comm=$1 argv0=${3:-} base
  [ -n "$comm" ] || [ -n "$argv0" ] || return 1
  argv0=${argv0:-$comm}
  base=$(basename -- "$comm")
  base=${base#-}
  case "$base" in
    grok) return 0 ;;
    agent|MainThread|node|node-*|node[0-9]*)
      cs_grok_argv0_is_grok "$argv0" && return 0
      cs_grok_path_is_grok "$comm" && return 0
      return 1
      ;;
  esac
  case "$comm" in
    */*) cs_grok_path_is_grok "$comm" && return 0 ;;
  esac
  return 1
}

cs_grok_json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# cs_grok_exclude_worktree_pointer <worktree> - gitignore the turn-end pointer.
cs_grok_exclude_worktree_pointer() {
  local wt=$1 excl
  EXCL=$(git -C "$wt" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$EXCL" ] || return 0
  grep -Fqx '.cs-grok-turnend' "$EXCL" 2>/dev/null || printf '%s\n' '.cs-grok-turnend' >> "$EXCL"
}

# cs_grok_turnend_arm <turnend> <state> <id> <worktree> [telemetry-cmd] -
# install the global Stop hook and drop the per-task pointer/registry entry.
cs_grok_turnend_arm() {
  local turnend=$1 state=$2 id=$3 wt=$4 telemetry=${5:-}
  local hooks_dir auth_dir hook_sh hook_json sq_auth old_umask token auth_file
  local after_touch=''
  [ -n "$turnend" ] && [ -n "$state" ] && [ -n "$id" ] && [ -n "$wt" ] || return 1
  case "$turnend" in
    *'"'*|*\\*|*\'*|*[[:cntrl:]]*) return 1 ;;
  esac
  if [ -n "$telemetry" ]; then
    case "$telemetry" in
      *[[:cntrl:]]*) return 1 ;;
    esac
    after_touch=$telemetry
  fi
  hooks_dir="$(cs_grok_home)/hooks"
  auth_dir="$hooks_dir/cs-turn-end.d"
  mkdir -p "$auth_dir" || return 1
  old_umask=$(umask)
  umask 077
  auth_file=$(mktemp "$auth_dir/cs.XXXXXXXXXXXX") || { umask "$old_umask"; return 1; }
  umask "$old_umask"
  printf '%s\n' "$turnend" > "$auth_file" || return 1
  token=${auth_file##*/}
  printf '%s\n' "$token" > "$state/$id.grok-turnend-token" || return 1
  sq_auth=$(cs_grok_shell_quote "$auth_dir")
  hook_sh="$hooks_dir/cs-turn-end.sh"
  cat > "$hook_sh" <<EOF
#!/usr/bin/env bash
set -u
auth_dir=$sq_auth
workspace=\${GROK_WORKSPACE_ROOT:-}
[ -n "\$workspace" ] || exit 0
p="\$workspace/.cs-grok-turnend"
[ -f "\$p" ] || exit 0
first=
IFS= read -r -n 256 first < "\$p" 2>/dev/null || [ -n "\$first" ] || exit 0
case "\$first" in token=*) token=\${first#token=} ;; *) exit 0 ;; esac
case "\$token" in cs.????????????) : ;; *) exit 0 ;; esac
case "\$token" in *[!A-Za-z0-9._-]*) exit 0 ;; esac
t=\$(cat "\$auth_dir/\$token" 2>/dev/null) || exit 0
case "\$t" in /*.turn-ended) : ;; *) exit 0 ;; esac
touch "\$t" 2>/dev/null || true
EOF
  if [ -n "$after_touch" ]; then
    printf '%s\n' "$after_touch" >> "$hook_sh"
  fi
  printf 'exit 0\n' >> "$hook_sh"
  chmod +x "$hook_sh" || return 1
  hook_json="$hooks_dir/cs-turn-end.json"
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' \
    "$(cs_grok_json_escape "bash $(cs_grok_shell_quote "$hook_sh")")" > "$hook_json" || return 1
  printf 'token=%s\n' "$token" > "$wt/.cs-grok-turnend" || return 1
  cs_grok_exclude_worktree_pointer "$wt" || true
}

# cs_grok_turnend_disarm <state> <id> <worktree> - teardown cleanup.
cs_grok_turnend_disarm() {
  local state=$1 id=$2 wt=$3 token auth_dir
  [ -n "$state" ] && [ -n "$id" ] || return 0
  token=$(sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;}' "$state/$id.grok-turnend-token" 2>/dev/null || true)
  rm -f "$state/$id.grok-turnend-token"
  [ -n "$wt" ] && rm -f "$wt/.cs-grok-turnend"
  [ -n "$token" ] || return 0
  auth_dir="$(cs_grok_home)/hooks/cs-turn-end.d"
  rm -f "$auth_dir/$token"
}
