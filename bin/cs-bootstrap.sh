#!/usr/bin/env bash
# Session-start bootstrap: detect-only diagnostics, plus the mutating sweeps
# when this session holds the lock.
#
# DETECT-ONLY checks (always run; silent when healthy):
#   MISSING: <tool> ...        a required tool is absent; consigliere must not
#                              dispatch until it is present. Optional tools print
#                              BOOTSTRAP_INFO instead. Both lists come from
#                              cs-deps-lib.sh, their single owner, which
#                              bin/cs-doctor.sh reports from as well.
#                              The axi-family tools are also version-gated here:
#                              an installed build below its floor reports through
#                              the same MISSING / BOOTSTRAP_INFO line as an
#                              absent tool, so the operator is asked to upgrade
#                              before anything is dispatched instead of silently
#                              running an older build. This script owns the
#                              floors and their policy: every floor is the
#                              CURRENT LATEST published version of its tool,
#                              bumped deliberately and periodically - never the
#                              minimum version that introduces some depended-on
#                              behavior (see the constants below).
#   HERDR_DOWN / HERDR_PROTOCOL:  the herdr server is unreachable or below the
#                              minimum protocol (docs/herdr.md).
#   NEEDS_GH_AUTH              gh is present but not authenticated.
#   TANGLE: ...                the primary checkout is on a named non-default
#                              branch (cs-tangle-lib.sh owns classification);
#                              resolve without touching unlanded work.
#
# MUTATING sweeps (skipped under CS_BOOTSTRAP_DETECT_ONLY=1, i.e. a read-only
# session; each also skipped silently while its owning script is not yet
# installed):
#   FLEET_SYNC: ...            refresh project clones (bin/cs-fleet-sync.sh).
#   CAPO_SYNC: / CAPO_LIVENESS: fast-forward and respawn registered capos
#                              (bin/cs-home-seed.sh sweep modes).
#
# Silent output means all good. Any printed actionable line names its owner.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
PROJECTS="${CS_PROJECTS_OVERRIDE:-$CS_HOME/projects}"
DETECT_ONLY=${CS_BOOTSTRAP_DETECT_ONLY:-0}

# --- required tools ----------------------------------------------------------
# The required/optional inventory (including which harness is required: the ROOT
# session's own) is owned by cs-deps-lib.sh, shared with bin/cs-doctor.sh, so the
# in-session gate and the human preflight report can never disagree.
# shellcheck source=bin/cs-harness-lib.sh
. "$SCRIPT_DIR/cs-harness-lib.sh"
# shellcheck source=bin/cs-deps-lib.sh
. "$SCRIPT_DIR/cs-deps-lib.sh"

# AXI-FAMILY FLOOR POLICY. Every floor below is the CURRENT LATEST published
# version of its tool at the time it was set, bumped deliberately and
# periodically to move the whole fleet onto the newest axi tools. A floor is
# NOT the minimum version that happens to introduce some behavior consigliere
# depends on: never argue a floor down to the earliest release that satisfies
# one feature, and never justify one with a feature citation - verify the
# tool's current published latest and bump. cs-tasks-lib.sh's tasks-axi feature
# probes are a separate defense-in-depth concern, not part of its floor.
# Each floor: the tool's published latest, verified 2026-08-06.
CS_GH_AXI_MIN=0.1.29
CS_TASKS_AXI_MIN=0.2.4
CS_LAVISH_AXI_MIN=0.1.45
CS_QUOTA_AXI_MIN=0.1.17

# cs_bootstrap_axi_floor <tool> - the tool's floor, or nonzero for a tool the
# policy above does not gate.
cs_bootstrap_axi_floor() {
  case "$1" in
    gh-axi) printf '%s\n' "$CS_GH_AXI_MIN" ;;
    tasks-axi) printf '%s\n' "$CS_TASKS_AXI_MIN" ;;
    lavish-axi) printf '%s\n' "$CS_LAVISH_AXI_MIN" ;;
    quota-axi) printf '%s\n' "$CS_QUOTA_AXI_MIN" ;;
    *) return 1 ;;
  esac
}

# cs_bootstrap_axi_gap <tool> - when the installed tool is below its floor,
# print "<installed-or-unparseable> below floor <floor> - upgrade: <hint>" and
# exit 0; silent exit 1 when the tool is ungated, absent, or at/above its floor.
cs_bootstrap_axi_gap() {
  local tool=$1 floor installed
  floor=$(cs_bootstrap_axi_floor "$tool") || return 1
  cs_deps_version_at_least "$tool" "$floor" && return 1
  installed=$(cs_deps_version "$tool" || true)
  printf '%s below floor %s - upgrade: %s\n' \
    "${installed:-unparseable version}" "$floor" "$(cs_deps_hint "$tool")"
}

missing=""
outdated=""
while IFS= read -r tool; do
  [ -n "$tool" ] || continue
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing="$missing $tool"
  elif gap=$(cs_bootstrap_axi_gap "$tool"); then
    outdated="$outdated$tool $gap"$'\n'
  fi
done <<EOF
$(cs_deps_tools required)
EOF
[ -z "$missing" ] || printf 'MISSING:%s - install before dispatching; consigliere cannot operate without these. bin/cs-doctor.sh reports versions and install suggestions.\n' "$missing"
[ -z "$outdated" ] || printf '%s' "$outdated" | sed 's/^/MISSING: /'

while IFS= read -r tool; do
  [ -n "$tool" ] || continue
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'BOOTSTRAP_INFO: optional tool %s not installed.\n' "$tool"
  elif gap=$(cs_bootstrap_axi_gap "$tool"); then
    printf 'BOOTSTRAP_INFO: optional tool %s %s\n' "$tool" "$gap"
  fi
done <<EOF
$(cs_deps_tools optional)
EOF

# --- herdr server health -------------------------------------------------------
if command -v herdr >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  # shellcheck source=bin/cs-herdr-lib.sh
  . "$SCRIPT_DIR/cs-herdr-lib.sh"
  status=$(cs_herdr status --json 2>/dev/null || true)
  if [ -z "$status" ]; then
    printf 'HERDR_DOWN: cannot reach the herdr server for session %s; start it (herdr) before dispatching.\n' "$(cs_herdr_session)"
  else
    running=$(printf '%s' "$status" | jq -r '.server.running // false')
    proto=$(printf '%s' "$status" | jq -r '.server.protocol // 0')
    if [ "$running" != true ]; then
      printf 'HERDR_DOWN: herdr server not running for session %s.\n' "$(cs_herdr_session)"
    elif [ "$proto" -lt "$CS_HERDR_MIN_PROTOCOL" ] 2>/dev/null; then
      printf 'HERDR_PROTOCOL: server protocol %s below required %s; update herdr (docs/herdr.md).\n' "$proto" "$CS_HERDR_MIN_PROTOCOL"
    fi
  fi
fi

# --- gh auth -------------------------------------------------------------------
if command -v gh >/dev/null 2>&1; then
  gh auth status >/dev/null 2>&1 || printf 'NEEDS_GH_AUTH: gh is not authenticated; run gh auth login before dispatching PR-based work.\n'
fi

# --- worktree tangle -------------------------------------------------------------
if [ -x "$SCRIPT_DIR/cs-tangle-lib.sh" ] || [ -f "$SCRIPT_DIR/cs-tangle-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/cs-tangle-lib.sh" 2>/dev/null || true
  if command -v cs_tangle_check >/dev/null 2>&1; then
    tangle=$(cs_tangle_check "$CS_ROOT" 2>/dev/null || true)
    [ -z "$tangle" ] || printf 'TANGLE: %s\n' "$tangle"
  fi
fi

# --- mutating sweeps ----------------------------------------------------------
if [ "$DETECT_ONLY" != 1 ]; then
  if [ -x "$SCRIPT_DIR/cs-fleet-sync.sh" ] && [ -d "$PROJECTS" ]; then
    sync_out=$("$SCRIPT_DIR/cs-fleet-sync.sh" --all 2>&1) || true
    [ -z "$sync_out" ] || printf '%s\n' "$sync_out" | sed 's/^/FLEET_SYNC: /'
  fi
  if [ -x "$SCRIPT_DIR/cs-home-seed.sh" ] && [ -f "$HOST_DIR/capos.md" ]; then
    capo_out=$("$SCRIPT_DIR/cs-home-seed.sh" --sweep 2>&1) || true
    [ -z "$capo_out" ] || printf '%s\n' "$capo_out"
  fi
fi

exit 0
