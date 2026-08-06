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

missing=""
while IFS= read -r tool; do
  [ -n "$tool" ] || continue
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done <<EOF
$(cs_deps_tools required)
EOF
[ -z "$missing" ] || printf 'MISSING:%s - install before dispatching; consigliere cannot operate without these. bin/cs-doctor.sh reports versions and install suggestions.\n' "$missing"

while IFS= read -r tool; do
  [ -n "$tool" ] || continue
  command -v "$tool" >/dev/null 2>&1 || printf 'BOOTSTRAP_INFO: optional tool %s not installed.\n' "$tool"
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
