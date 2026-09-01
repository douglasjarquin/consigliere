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
#                              Five of those tools are also version-gated:
#                              Python 3.11+ with stdlib tomllib, gh-axi,
#                              tasks-axi, lavish-axi, and quota-axi. An
#                              installed build below its floor reports through
#                              the same MISSING / BOOTSTRAP_INFO line as an
#                              absent tool, so the operator is asked to upgrade
#                              before anything is dispatched instead of silently
#                              running an older build. chrome-devtools-axi is
#                              deliberately not gated; cs-deps-lib.sh states why
#                              beside cs_deps_axi_floor. The floors and their
#                              bump policy live there too, next to the shared
#                              comparator, so bin/cs-doctor.sh's preflight gates
#                              the same builds this dispatch gate does.
#   HERDR_DOWN / HERDR_PROTOCOL:  the herdr server is unreachable or below the
#                              minimum protocol (docs/herdr.md).
#   MADE_DOWN                  the made daemon is unreachable; start it with
#                              made daemon start before dispatching.
#   NEEDS_GH_AUTH              gh is present but not authenticated.
#   TANGLE: ...                the primary checkout is on a named non-default
#                              branch (cs-tangle-lib.sh owns classification);
#                              resolve without touching unlanded work.
#   BASH_FLOOR: ...            the running bash is below bin/cs-deps-lib.sh's
#                              declared floor. This one REFUSES (exit 1)
#                              instead of reporting and continuing - the only
#                              blocker that does - and bin/cs-session-start.sh
#                              honours that exit by refusing the session: the
#                              nameref argv builders fail OPEN below the
#                              floor, so continuing would dispatch soldiers
#                              with an empty autonomy argv.
#
# MUTATING sweeps (skipped under CS_BOOTSTRAP_DETECT_ONLY=1, i.e. a read-only
# session; each also skipped silently while its owning script is not yet
# installed):
#   FLEET_SYNC: ...            refresh project clones (bin/cs-fleet-sync.sh).
#   herdr event plugin         install this home's push-event transport
#                              (bin/cs-herdr-event-plugin.sh); idempotent, and a
#                              failure reports BOOTSTRAP_INFO rather than
#                              blocking - the watcher keeps its poll loop.
#   CAPO_SYNC: / CAPO_LIVENESS: fast-forward and respawn registered capos
#                              (bin/cs-home-seed.sh sweep modes).
#
# Set CS_BOOTSTRAP_LOCKED=1 alongside CS_BOOTSTRAP_DETECT_ONLY=1 when the
# sweeps are skipped because THIS session already ran them while holding the
# fleet lock (a cs-session-start.sh --reemit), rather than because it has no
# lock at all. The two cases differ in exactly one place: repair ownership.
# A locked session is told to restore a tangled primary checkout itself, while
# an unlocked one is told to leave that work to the lock holder. Unset/0 (the
# default) keeps detect-only meaning unlocked, exactly as before.
#
# NETWORK PHASE SPLIT. Set CS_BOOTSTRAP_NETWORK to split this run by whether a
# step talks to the network, so a session start can print its digest from local
# reads alone and run the network half concurrently:
#   all  (default, and any unrecognized value) - everything, exactly as before.
#        Unrecognized values fall back here on purpose: a typo must never
#        silently skip a safety sweep.
#   skip - every LOCAL step, and none of the network ones. Skips the `gh auth
#        status` probe and the fleet sync.
#   only - ONLY those network steps and nothing else. No tool detection, no
#        version floors, no herdr health probe, no tangle check, no capo sweep:
#        those already ran on the local pass.
# The two halves are a strict PARTITION of the unsplit run - every step lands in
# exactly one of them - so `skip` plus `only` is `all` with nothing added and
# nothing lost. CS_BOOTSTRAP_DETECT_ONLY composes with it unchanged, so `only`
# plus detect-only is the read-only `gh auth status` probe on its own.
# bin/cs-startup-network.sh owns the deferral: it runs the `only` phase in a
# detached bounded worker and publishes the result. This file stays the single
# owner of every sweep, and the split changes only WHEN each runs, never
# WHETHER.
# The capo sweep is deliberately in the LOCAL half: a capo home is a plain
# detached git worktree of this repo on this same machine, its fast-forward
# resolves against the primary checkout with no fetch, and its liveness probe
# asks the local herdr server, so nothing in it leaves the machine.
# CS_BOOTSTRAP_NETWORK_LOCK_PID, when set, is the state/.lock owner the deferred
# worker captured while that session still held the lock. Each network mutating
# sweep re-verifies it immediately before running, because a worker that
# outlives the command which launched it must never sweep on behalf of a session
# that has gone away. A changed owner reports a NETWORK_CHECKS: line and skips
# that sweep rather than running it.
#
# Silent output means all good. Any printed actionable line names its owner.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A pre-floor bash fails OPEN in the nameref argv builders (`local -n` errors,
# the caller's array stays empty, rc stays 0), so a soldier would launch with
# no autonomy flag and cs_herdr would drop --session from every call. Refuse
# here, at the gate every home runs. bin/cs-deps-lib.sh owns the floor, beside
# the axi-family floors this gate and bin/cs-doctor.sh both read.
# shellcheck source=bin/cs-deps-lib.sh
. "$SCRIPT_DIR/cs-deps-lib.sh"
case "${BASH_FLOOR_MAJOR:-}" in ''|*[!0-9]*) BASH_FLOOR_MAJOR= ;; esac
case "${BASH_FLOOR_MINOR:-}" in ''|*[!0-9]*) BASH_FLOOR_MINOR= ;; esac
if [ -z "$BASH_FLOOR_MAJOR" ] || [ -z "$BASH_FLOOR_MINOR" ]; then
  printf 'BASH_FLOOR: bin/cs-deps-lib.sh did not provide BASH_FLOOR_MAJOR/BASH_FLOOR_MINOR; refusing to run on an unverified interpreter.\n' >&2
  exit 1
fi
if [ "${BASH_VERSINFO[0]}" -lt "$BASH_FLOOR_MAJOR" ] ||
  { [ "${BASH_VERSINFO[0]}" -eq "$BASH_FLOOR_MAJOR" ] &&
    [ "${BASH_VERSINFO[1]}" -lt "$BASH_FLOOR_MINOR" ]; }; then
  printf 'BASH_FLOOR: bash %s is below the required %s.%s (the nameref argv builders in bin/cs-herdr-lib.sh and bin/cs-harness-lib.sh fail open below it); do not dispatch from this interpreter.\n' \
    "${BASH_VERSION%%(*}" "$BASH_FLOOR_MAJOR" "$BASH_FLOOR_MINOR" >&2
  exit 1
fi

# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
PROJECTS="${CS_PROJECTS_OVERRIDE:-$CS_HOME/projects}"
DETECT_ONLY=${CS_BOOTSTRAP_DETECT_ONLY:-0}

# Network-phase selection (see the header). An unrecognized value resolves to
# `all` so a malformed override runs every step rather than silently dropping a
# safety sweep.
case "${CS_BOOTSTRAP_NETWORK:-all}" in
  skip|only) NETWORK_PHASE=${CS_BOOTSTRAP_NETWORK:-all} ;;
  *) NETWORK_PHASE=all ;;
esac
local_phase() { [ "$NETWORK_PHASE" != only ]; }
network_phase() { [ "$NETWORK_PHASE" != skip ]; }

# The deferred worker outlives the session start that launched it, so "my
# session held the lock a moment ago" is not enough authority for a mutating
# sweep. Whether state/.lock STILL names the session that asked is bin/cs-lock.sh's
# `holds` mode, which owns that predicate for every caller; its header states the
# contract. An unset expectation means an ordinary in-session run, which needs no
# re-verification.
network_mutation_authorized() {
  local expected=${CS_BOOTSTRAP_NETWORK_LOCK_PID:-}
  [ -n "$expected" ] || return 0
  "$SCRIPT_DIR/cs-lock.sh" holds "$expected" 2>/dev/null
}

network_sweep_authorized() {  # <label>
  if network_mutation_authorized; then
    return 0
  fi
  echo "NETWORK_CHECKS: fleet lock ownership changed before $1, so this stale worker skipped that sweep"
  return 1
}

# --- required tools ----------------------------------------------------------
# The required/optional inventory (including which harness is required: the ROOT
# session's own) is owned by cs-deps-lib.sh, shared with bin/cs-doctor.sh, so the
# in-session gate and the human preflight report can never disagree.
# shellcheck source=bin/cs-harness-lib.sh
. "$SCRIPT_DIR/cs-harness-lib.sh"
# shellcheck source=bin/cs-deps-lib.sh
. "$SCRIPT_DIR/cs-deps-lib.sh"
# Each sweep below is bracketed by one elapsed-time record, so a slow run is
# attributable to a step rather than only to the run as a whole. Recording is
# inert unless the run that launched this one asked for it (bin/cs-timing-lib.sh),
# so an ordinary bootstrap pays nothing for the instrumentation.
# shellcheck source=bin/cs-timing-lib.sh
. "$SCRIPT_DIR/cs-timing-lib.sh"

# cs_bootstrap_tool_gap <tool> - the session-start wording for the below-floor
# or capability classification cs-deps-lib.sh owns, then exit 0; exit 1
# silently when the tool is ungated, absent, or at/above its floor.
cs_bootstrap_tool_gap() {
  local tool=$1 gap installed floor reason
  gap=$(cs_deps_tool_gap "$tool") || return 1
  IFS=$'\t' read -r installed floor reason <<< "$gap"
  if [ "$reason" = tomllib ]; then
    printf '%s lacks stdlib tomllib - install Python %s+; %s\n' \
      "$installed" "$floor" "$(cs_deps_hint "$tool")"
  else
    printf '%s below floor %s - upgrade: %s\n' \
      "$installed" "$floor" "$(cs_deps_hint "$tool")"
  fi
}

# Local detection: tool presence, version floors, and the herdr server probe.
# Nothing here leaves this machine, so it stays on the session-start critical
# path.
detect_local_tools() {
  local missing="" outdated="" tool gap status running proto
  while IFS= read -r tool; do
    [ -n "$tool" ] || continue
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing="$missing $tool"
    elif gap=$(cs_bootstrap_tool_gap "$tool"); then
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
    elif gap=$(cs_bootstrap_tool_gap "$tool"); then
      printf 'BOOTSTRAP_INFO: optional tool %s %s\n' "$tool" "$gap"
    fi
  done <<EOF
$(cs_deps_tools optional)
EOF

  # --- herdr server health -----------------------------------------------------
  # Local: the herdr server runs on this machine, so this probe never leaves it.
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

  # --- made daemon health -------------------------------------------------
  # Local: made's daemon is reached over a local unix socket (internal/api),
  # so this probe never leaves the machine either.
  if command -v made >/dev/null 2>&1; then
    # shellcheck source=bin/cs-made-lib.sh
    . "$SCRIPT_DIR/cs-made-lib.sh"
    # `made status --json` fails BOTH when the daemon is unreachable and when
    # the daemon is healthy but has run nothing yet ("no runs found") - unlike
    # herdr's status probe above, a nonzero exit here is not on its own proof
    # of an unreachable daemon. Grepping stderr for made's own
    # "daemon not reachable" wording (cmd/made/status.go) tells the two apart.
    # shellcheck disable=SC2119  # cs_made_status with no run-id means "latest"
    made_err=$(cs_made_status 2>&1 >/dev/null) || true
    if printf '%s' "$made_err" | grep -q 'daemon not reachable'; then
      printf 'MADE_DOWN: cannot reach the made daemon; start it (made daemon start) before dispatching.\n'
    fi
  fi
}

# --- gh auth -------------------------------------------------------------------
# The one detect-only step that leaves this machine.
# shellcheck disable=SC2329  # Invoked through cs_timed, which brackets it with one record.
detect_gh_auth() {
  if command -v gh >/dev/null 2>&1; then
    gh auth status >/dev/null 2>&1 || printf 'NEEDS_GH_AUTH: gh is not authenticated; run gh auth login before dispatching PR-based work.\n'
  fi
}

# --- worktree tangle -------------------------------------------------------------
detect_local_config() {
  local tangle_branch tangle_default
  # shellcheck source=bin/cs-tangle-lib.sh
  . "$SCRIPT_DIR/cs-tangle-lib.sh"
  tangle_branch=$(cs_primary_tangle_branch "$CS_ROOT" 2>/dev/null || true)
  if [ -n "$tangle_branch" ]; then
    tangle_default=$(cs_default_branch "$CS_ROOT" 2>/dev/null || echo main)
    if [ "$DETECT_ONLY" = 1 ] && [ "${CS_BOOTSTRAP_LOCKED:-0}" != 1 ]; then
      printf "TANGLE: primary checkout on feature branch '%s' (expected '%s'); the work is safe on that ref - read-only session must leave restore work to the session holding the fleet lock\n" "$tangle_branch" "$tangle_default"
    else
      printf "TANGLE: primary checkout on feature branch '%s' (expected '%s'); the work is safe on that ref - restore the primary with: git -C %s checkout %s, then re-validate the branch in a proper worktree\n" "$tangle_branch" "$tangle_default" "$CS_ROOT" "$tangle_default"
    fi
  fi
}

# The order below is the order the diagnostics have always printed in, so a
# `skip` run is the same output with the network lines removed rather than a
# reshuffle, and `gh auth status` keeps the position it has always had.
local_phase && detect_local_tools
network_phase && cs_timed gh-auth '' detect_gh_auth
local_phase && detect_local_config

# --- mutating sweeps ----------------------------------------------------------
if [ "$DETECT_ONLY" != 1 ]; then
  if network_phase && [ -x "$SCRIPT_DIR/cs-fleet-sync.sh" ] && [ -d "$PROJECTS" ] \
    && network_sweep_authorized 'project clone refresh'; then
    sync_out=$(cs_timed clone-refresh '' "$SCRIPT_DIR/cs-fleet-sync.sh" --all 2>&1) || true
    [ -z "$sync_out" ] || printf '%s\n' "$sync_out" | sed 's/^/FLEET_SYNC: /'
  fi
  # Local: the herdr event plugin is a machine-local registration this home owns
  # (bin/cs-herdr-event-plugin.sh). Re-running install is idempotent and never
  # required: a failure here costs blocked-escalation latency, not supervision,
  # so it reports and moves on rather than gating dispatch.
  if local_phase && [ -x "$SCRIPT_DIR/cs-herdr-event-plugin.sh" ] && command -v herdr >/dev/null 2>&1; then
    if ! plugin_out=$("$SCRIPT_DIR/cs-herdr-event-plugin.sh" install 2>&1); then
      printf 'BOOTSTRAP_INFO: herdr event plugin not installed (%s); supervision continues on the poll loop.\n' \
        "$(printf '%s' "$plugin_out" | tail -n 1)"
    fi
  fi
  # Local: capo homes are detached worktrees of this repo on this machine, and
  # their liveness probe asks the local herdr server (see the header).
  if local_phase && [ -x "$SCRIPT_DIR/cs-home-seed.sh" ] && [ -f "$HOST_DIR/capos.md" ]; then
    capo_out=$("$SCRIPT_DIR/cs-home-seed.sh" --sweep 2>&1) || true
    [ -z "$capo_out" ] || printf '%s\n' "$capo_out"
  fi
  if local_phase && [ -x "$SCRIPT_DIR/cs-backlog-handoff.sh" ]; then
    "$SCRIPT_DIR/cs-backlog-handoff.sh" --resume-pending >/dev/null 2>&1 || true
  fi
fi

exit 0
