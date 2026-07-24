#!/usr/bin/env bash
# Session-start bootstrap: detect-only diagnostics, plus the mutating sweeps
# when this session holds the lock.
#
# DETECT-ONLY checks (always run; silent when healthy):
#   MISSING: <tool> ...        a required tool is absent (herdr, the ROOT
#                              session's harness - codex or claude - jq, gh,
#                              gh-axi); consigliere must not dispatch until
#                              present. Optional tools (the other harness,
#                              tasks-axi, no-mistakes, lavish-axi,
#                              chrome-devtools-axi) print BOOTSTRAP_INFO instead.
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
# The required harness is the ROOT session's own (codex or claude); the other
# harness is optional. Everything else is unconditionally required.
# shellcheck source=bin/cs-harness-lib.sh
. "$SCRIPT_DIR/cs-harness-lib.sh"
ROOT_HARNESS=$(cs_harness_detect_root)
ROOT_HARNESS_BIN=$(cs_harness_binary "$ROOT_HARNESS")
OTHER_HARNESS_BIN=$([ "$ROOT_HARNESS" = codex ] && echo claude || echo codex)

missing=""
for tool in herdr "$ROOT_HARNESS_BIN" jq gh gh-axi git; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
[ -z "$missing" ] || printf 'MISSING:%s - install before dispatching; consigliere cannot operate without these.\n' "$missing"

for tool in "$OTHER_HARNESS_BIN" tasks-axi no-mistakes lavish-axi chrome-devtools-axi; do
  command -v "$tool" >/dev/null 2>&1 || printf 'BOOTSTRAP_INFO: optional tool %s not installed.\n' "$tool"
done

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
  if [ -x "$SCRIPT_DIR/cs-home-seed.sh" ] && [ -f "$DATA/capos.md" ]; then
    capo_out=$("$SCRIPT_DIR/cs-home-seed.sh" --sweep 2>&1) || true
    [ -z "$capo_out" ] || printf '%s\n' "$capo_out"
  fi
fi

exit 0
