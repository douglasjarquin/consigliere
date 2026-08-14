#!/usr/bin/env bash
# cs-doctor.sh - preflight dependency report for a human, before a first session.
#
# CHECKS ONLY. This script never installs, upgrades, configures, or authenticates
# anything: the same dependency legitimately arrives by brew, npm, a native
# installer, or a hand-built binary, and consigliere has no business overriding
# how this machine is set up. It reports what is present, what version, what is
# missing, and suggests an install channel for each gap.
#
# Relationship to session start: bin/cs-bootstrap.sh performs the same required/
# optional detection from inside a live session, terse and machine-readable, as a
# dispatch gate. cs-doctor.sh is the human-readable superset run BEFORE that -
# versions, the herdr server, gh auth, and the contributor tools bootstrap stays
# silent about. Both read one inventory (bin/cs-deps-lib.sh), so they cannot
# disagree about what consigliere depends on. That library also owns the
# axi-family version floors and their bump policy, and this report gates on them
# through it rather than restating a number: a build session start would refuse
# is never reported ready here.
#
# Usage:
#   cs-doctor.sh            print the report
#   cs-doctor.sh --help     print this usage
#
# Exit status:
#   0  every required dependency is present and every service check passed
#   1  at least one required dependency or service check failed; do not dispatch
# Optional and contributor gaps never fail the run - they are reported as the
# named capability that is unavailable.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Checks-only bypass of the layout gate: the doctor reports an unmigrated home
# as a named failure in its config section instead of dying before it can say
# anything useful.
CS_LAYOUT_GATE_SKIP=1
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
CS_LAYOUT_GATE_SKIP=
# shellcheck source=bin/cs-deps-lib.sh
. "$SCRIPT_DIR/cs-deps-lib.sh"
# shellcheck source=bin/cs-herdr-lib.sh
. "$SCRIPT_DIR/cs-herdr-lib.sh"
# shellcheck source=bin/cs-telemetry-lib.sh
. "$SCRIPT_DIR/cs-telemetry-lib.sh"

case "${1:-}" in
  -h|--help)
    # Print the header comment block itself, so help can never drift from it.
    awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
    exit 0
    ;;
  '') ;;
  *)
    printf 'cs-doctor.sh: unknown argument "%s" (see --help)\n' "$1" >&2
    exit 2
    ;;
esac

# Stock macOS ships bash 3.2; every script in this repo stays compatible with it,
# so that is the floor rather than whatever the developer's newer bash provides.
BASH_FLOOR_MAJOR=3
BASH_FLOOR_MINOR=2

PROBLEMS=0

say() { printf '%s\n' "$*"; }
heading() { printf '\n%s\n' "$1"; }

# report <marker> <name> <version-or-dash> <note>
# The marker column is as wide as the widest marker ("MISSING") so every column
# stays aligned and the report is greppable line by line.
report() {
  printf '  %-7s %-21s %-12s %s\n' "$1" "$2" "${3:--}" "$4"
}

suggest() {
  printf '          -> %s\n' "$1"
}

problem() {
  PROBLEMS=$((PROBLEMS + 1))
}

# below_floor <tool> - true when the below-floor classification cs-deps-lib.sh
# owns applies to <tool>. Sets FLOOR and FLOOR_VERSION for the caller's report
# line, so this report and the session-start gate describe the same build with
# the same version and the same floor.
FLOOR=
FLOOR_VERSION=
below_floor() {
  local gap
  gap=$(cs_deps_axi_gap "$1") || return 1
  IFS=$'\t' read -r FLOOR_VERSION FLOOR <<< "$gap"
}

# --- header -------------------------------------------------------------------

say 'consigliere doctor - dependency preflight (checks only; installs nothing)'
say "repo   $CS_ROOT"
if [ -n "${CS_HARNESS_OVERRIDE:-}" ]; then
  say "harness $(cs_harness_detect_root) (from CS_HARNESS_OVERRIDE)"
elif [ -f "$HOST_DIR/harness.conf" ]; then
  say "harness $(cs_harness_detect_root) (from host/harness.conf)"
else
  say "harness $(cs_harness_detect_root) (auto-detected; host/harness.conf overrides)"
fi

# --- required -----------------------------------------------------------------

heading 'REQUIRED - consigliere must not dispatch without these'
while IFS= read -r tool; do
  [ -n "$tool" ] || continue
  if version=$(cs_deps_version "$tool"); then
    if below_floor "$tool"; then
      report MISSING "$tool" "$FLOOR_VERSION" "below the $FLOOR floor; session start refuses to dispatch until it is upgraded"
      suggest "$(cs_deps_hint "$tool")"
      problem
    else
      report ok "$tool" "$version" "$(cs_deps_purpose "$tool")"
    fi
  else
    report MISSING "$tool" - "$(cs_deps_purpose "$tool")"
    suggest "$(cs_deps_hint "$tool")"
    problem
  fi
done <<EOF
$(cs_deps_tools required)
EOF

# --- services -----------------------------------------------------------------
#
# Present-on-PATH is not the same as usable: herdr needs a reachable server at or
# above the protocol floor its runtime owner gates on, and gh needs a live login.

heading 'SERVICES - a present tool is not yet a working one'

if command -v herdr >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  session=$(cs_herdr_session)
  status=$(cs_herdr status --json 2>/dev/null || true)
  if [ -z "$status" ]; then
    report MISSING "herdr server" - "unreachable for session $session"
    suggest "start it by running: herdr"
    problem
  else
    running=$(printf '%s' "$status" | jq -r '.server.running // false')
    proto=$(printf '%s' "$status" | jq -r '.server.protocol // 0')
    if [ "$running" != true ]; then
      report MISSING "herdr server" - "not running for session $session"
      suggest "start it by running: herdr"
      problem
    elif ! [ "$proto" -ge "$CS_HERDR_MIN_PROTOCOL" ] 2>/dev/null; then
      report MISSING "herdr server" "protocol $proto" "below the required $CS_HERDR_MIN_PROTOCOL (docs/herdr.md)"
      suggest "$(cs_deps_hint herdr)"
      problem
    else
      report ok "herdr server" "protocol $proto" "running for session $session"
    fi
  fi
else
  report SKIP "herdr server" - 'not checked: herdr or jq is missing'
fi

if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    report ok "gh auth" - 'authenticated'
  else
    report MISSING "gh auth" - 'gh is installed but not logged in'
    suggest 'gh auth login'
    problem
  fi
else
  report SKIP "gh auth" - 'not checked: gh is missing'
fi

if [ "${BASH_VERSINFO[0]}" -gt "$BASH_FLOOR_MAJOR" ] ||
  { [ "${BASH_VERSINFO[0]}" -eq "$BASH_FLOOR_MAJOR" ] &&
    [ "${BASH_VERSINFO[1]}" -ge "$BASH_FLOOR_MINOR" ]; }; then
  report ok bash "${BASH_VERSION%%(*}" "at or above the ${BASH_FLOOR_MAJOR}.${BASH_FLOOR_MINOR} floor"
else
  report MISSING bash "${BASH_VERSION%%(*}" "below the required ${BASH_FLOOR_MAJOR}.${BASH_FLOOR_MINOR}"
  suggest 'brew install bash, or run under a newer bash'
  problem
fi

# --- config and host: the tree you back up, and the tier you never do ----------
#
# config/ is the user-owned tree and host/ is its machine-local sibling
# (docs/configuration.md owns the inventory). Everything here is a read:
# presence, names, and symlink targets. Failures are the two arrangements that
# silently lose boss data: an unmigrated home, and a symlink where a
# rename-writer or the host tier will sever or defeat it.

heading 'CONFIG + HOST - back up config/ wholesale; host/ is per-machine'

# 1. Migration state: any pre-move path is a hard failure naming the migrator.
UNMIGRATED=0
while IFS=$'\t' read -r old _; do
  if [ -e "$old" ] || [ -L "$old" ]; then
    report FAIL "$(basename "$old")" - "pre-move path still exists: $old"
    UNMIGRATED=1
    problem
  fi
done <<EOF
$(cs_layout_pairs)
EOF
if [ "$UNMIGRATED" -eq 1 ]; then
  suggest 'run bin/cs-migrate-config.sh (idempotent; safe on a live fleet)'
else
  report ok 'layout' - 'no pre-move paths; the config/ layout is in effect'
fi

# resolve_link_target <link> -> absolute target path (relative targets resolve
# against the link's own directory; the target need not exist).
resolve_link_target() {
  local t
  t=$(readlink "$1") || return 1
  case "$t" in
    /*) printf '%s\n' "$t" ;;
    *)  printf '%s/%s\n' "$(CDPATH='' cd -- "$(dirname "$1")" && pwd -P)" "$t" ;;
  esac
}

# 2-5. Known names, symlink visibility, host-tier tripwire, sever tripwire.
CONFIG_KNOWN=' boss.md boss-shared.md learnings.md memory-archive.md projects.md boards.md backlog.md done-archive.md note-archive.md charter.md backlog-backend.conf permission-mode.conf wedge-alarm.conf '
HOST_KNOWN=' capos.md harness.conf upstream.conf activation.conf telemetry.conf '
NEVER_SYMLINK=' backlog.md done-archive.md note-archive.md capos.md '

check_config_entry() {  # <path> <tier: flat|host>
  local entry=$1 tier=$2 name known target
  name=$(basename "$entry")
  if [ "$tier" = flat ]; then known=$CONFIG_KNOWN; else known=$HOST_KNOWN; fi
  case "$known" in
    *" $name "*) ;;
    *) report WARN "$name" - "not a known name for this tier; a stray, a leaked temp, or a typo ($entry)" ;;
  esac
  if [ -L "$entry" ]; then
    target=$(resolve_link_target "$entry" || echo '(unresolvable)')
    case "$NEVER_SYMLINK" in
      *" $name "*)
        report FAIL "$name" - "symlinked, but its writer replaces it by rename, severing the link -> $target"
        problem
        return
        ;;
    esac
    if [ "$tier" = host ]; then
      case "$target" in
        "$CS_HOME"/*) report ok "$name" - "symlink within the home -> $target" ;;
        *)
          report FAIL "$name" - "host-tier file symlinked outside this home -> $target"
          suggest 'host/ entries are per-machine; materialize a real file instead of sharing it'
          problem
          ;;
      esac
    else
      report ok "$name" - "symlink -> $target"
    fi
  fi
}

if [ -d "$CONFIG" ]; then
  for entry in "$CONFIG"/* "$CONFIG"/.[!.]*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    check_config_entry "$entry" flat
  done
fi
if [ -d "$HOST_DIR" ]; then
  for entry in "$HOST_DIR"/* "$HOST_DIR"/.[!.]*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    check_config_entry "$entry" host
  done
fi

# 6. Telemetry, an OPTIONAL machine-local capability. Off is the normal state and
# is reported as information, never as a warning or an error: a home that never
# enables it is fully healthy. A malformed explicit config names the exact
# problem and warns without failing the run, because telemetry can only ever stop
# recording - it can never stop a session (docs/telemetry.md).
TELEMETRY_STATUS=$(cs_telemetry_config_status)
case "$TELEMETRY_STATUS" in
  'enabled '*)
    if command -v jq >/dev/null 2>&1; then
      cs_telemetry_paths
      report ok telemetry "${TELEMETRY_STATUS#enabled }d" "recording to $CS_TELEMETRY_FILE"
    else
      report WARN telemetry - 'enabled but jq is missing, so nothing is recorded'
      suggest "$(cs_deps_hint jq)"
    fi
    ;;
  malformed*)
    report WARN telemetry - "host/telemetry.conf is ${TELEMETRY_STATUS#malformed }; telemetry stays off"
    suggest 'a telemetry.conf carries exactly "enabled true|false" and an optional "retain_days <n>" (docs/telemetry.md)'
    ;;
  *)
    report ok telemetry - 'disabled (optional; no host/telemetry.conf)'
    ;;
esac

# --- optional -----------------------------------------------------------------

heading 'OPTIONAL - absent means one capability is unavailable, nothing more'
while IFS= read -r tool; do
  [ -n "$tool" ] || continue
  if version=$(cs_deps_version "$tool"); then
    if below_floor "$tool"; then
      report WARN "$tool" "$FLOOR_VERSION" "below the $FLOOR floor; session start asks for an upgrade"
      suggest "$(cs_deps_hint "$tool")"
    else
      report ok "$tool" "$version" "$(cs_deps_purpose "$tool")"
    fi
  else
    report absent "$tool" - "$(cs_deps_purpose "$tool")"
    suggest "$(cs_deps_hint "$tool")"
  fi
done <<EOF
$(cs_deps_tools optional)
EOF

# --- contributor --------------------------------------------------------------

heading 'CONTRIBUTOR - only needed to change this repo (lint, tests, detached monitor handoff)'
pinned_shellcheck=$("$SCRIPT_DIR/cs-lint.sh" --required-version 2>/dev/null || true)
while IFS= read -r tool; do
  [ -n "$tool" ] || continue
  if version=$(cs_deps_version "$tool"); then
    if [ "$tool" = shellcheck ] && [ -n "$pinned_shellcheck" ] &&
      [ "$version" != "$pinned_shellcheck" ]; then
      report WARN "$tool" "$version" "CI pins $pinned_shellcheck exactly; bin/cs-lint.sh refuses another version"
      suggest "$(cs_deps_hint shellcheck)"
    else
      report ok "$tool" "$version" "$(cs_deps_purpose "$tool")"
    fi
  else
    report absent "$tool" - "$(cs_deps_purpose "$tool")"
    suggest "$(cs_deps_hint "$tool")"
  fi
done <<EOF
$(cs_deps_tools contributor)
EOF

# --- verdict ------------------------------------------------------------------

printf '\n'
if [ "$PROBLEMS" -eq 0 ]; then
  say 'Ready: every required dependency and service check passed.'
  exit 0
fi
if [ "$PROBLEMS" -eq 1 ]; then
  say '1 required problem above; fix it before starting a session.'
else
  say "$PROBLEMS required problems above; fix them before starting a session."
fi
say 'This script installs nothing - each -> line is a suggestion, not a command it ran.'
exit 1
