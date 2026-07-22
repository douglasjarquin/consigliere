#!/usr/bin/env bash
# tests/cs-watch-helpers.sh - shared fixtures and mocks for the cs-watch suite.
# Provides an offline case dir with a fake herdr CLI (pane read / agent get /
# status) and a fake cs-crew-state.sh, so the watcher's triage runs with no
# live backend, codex, or no-mistakes install. Generic reporters/assertions
# come from tests/lib.sh, pulled in below.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# make_case <name>: a fresh case dir under $TMP_ROOT with state/ and fakebin/
# containing the fake herdr and fake cs-crew-state.sh. Echoes the case dir.
make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
# Offline herdr stand-in for cs-watch tests. Driven by env:
#   CS_FAKE_HERDR_CAPTURE       file whose contents `pane read` prints
#   CS_FAKE_HERDR_AGENT_STATUS  agent_status returned by `agent get` (default idle)
#   CS_FAKE_HERDR_AGENT         agent name in `agent get` (default codex;
#                               exported EMPTY = no agent in the pane)
set -u
case "${1:-} ${2:-}" in
  "pane read")
    if [ -n "${CS_FAKE_HERDR_CAPTURE:-}" ]; then
      cat "$CS_FAKE_HERDR_CAPTURE" 2>/dev/null
    fi
    exit 0 ;;
  "agent get")
    status="${CS_FAKE_HERDR_AGENT_STATUS:-idle}"
    agent="${CS_FAKE_HERDR_AGENT-codex}"
    if [ -n "$agent" ]; then
      printf '{"result":{"agent":{"agent":"%s","agent_status":"%s"}}}\n' "$agent" "$status"
    else
      printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$status"
    fi
    exit 0 ;;
  "status --json")
    printf '{"server":{"protocol":16,"socket":"%s"},"client":{"protocol":16}}\n' "${CS_FAKE_HERDR_SOCKET:-}"
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/herdr"
  make_fake_crew_state "$fakebin" >/dev/null
  printf '%s\n' "$dir"
}

# Install a hermetic fake cs-crew-state.sh into <fakebin> and echo its path.
# The watcher's absorb-only-when-provably-working triage calls this (via
# CS_CREW_STATE_BIN) to read a soldier's current state on no-verb signal and
# stale paths; the fake returns a canned "state: <s> · source: <src> · <detail>"
# verdict line so a test can fix the provably-working decision without a real
# worktree or no-mistakes.
# A per-id override CS_FAKE_CREW_STATE_<sanitized-id> wins; otherwise the shared
# CS_FAKE_CREW_STATE; otherwise an unknown verdict (NOT provably working), the
# safe default so a test that forgets to set one surfaces rather than absorbs.
make_fake_crew_state() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/cs-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=${1:-}
key=$(printf '%s' "$id" | tr -c 'A-Za-z0-9' '_')
var="CS_FAKE_CREW_STATE_$key"
val=${!var:-${CS_FAKE_CREW_STATE:-}}
printf '%s\n' "${val:-state: unknown · source: none · fake default}"
exit 0
SH
  chmod +x "$fakebin/cs-crew-state.sh"
  printf '%s\n' "$fakebin/cs-crew-state.sh"
}

# watch_bg <state> <fakebin> <out> [VAR=val ...]: run the watcher in the
# background with the offline defaults (tight poll/grace, checks and heartbeat
# parked, event splice forced off so the terminal wait is a plain sleep).
# Extra VAR=val arguments override per test. The caller reads $! for the pid.
watch_bg() {
  local state=$1 fakebin=$2 out=$3
  shift 3
  env PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" \
    CS_CREW_STATE_BIN="$fakebin/cs-crew-state.sh" CS_HERDR_EVENTS_FORCE=0 \
    CS_POLL=1 CS_SIGNAL_GRACE=1 CS_CHECK_INTERVAL=999999 CS_HEARTBEAT=999999 \
    "$@" "$WATCH" > "$out" &
}

# Wait up to <limit> 0.1s ticks while <pid> stays alive; 0 if still alive, 1 if it died.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

is_live_non_zombie() {
  local pid=$1 stat
  kill -0 "$pid" 2>/dev/null || return 1
  stat=$(ps -p "$pid" -o stat= 2>/dev/null || true)
  case "$stat" in
    Z*) return 1 ;;
  esac
  return 0
}

wait_for_exit() {
  local pid=$1 limit=${2:-50} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! is_live_non_zombie "$pid"; then
      wait "$pid"
      return "$?"
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 124
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# Wait up to <limit> 0.1s ticks for <file> to hold a purely numeric value.
wait_numeric_file() {
  local file=$1 limit=${2:-30} i=0 value
  while [ "$i" -lt "$limit" ]; do
    value=$(cat "$file" 2>/dev/null || true)
    case "$value" in
      ''|*[!0-9]*) ;;
      *) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Count durable wake records of <kind> for <key> in <state>'s queue.
count_wakes() {  # <state> <kind> <key>
  awk -F '\t' -v k="$2" -v key="$3" '$3 == k && $4 == key { n++ } END { print n + 0 }' \
    "$1/.wake-queue" 2>/dev/null || echo 0
}

# Portable mtime in epoch seconds. Platform-detected, never the
# `stat -f || stat -c` fallback (which writes a partial filesystem dump on
# Linux; see cs-watch.sh).
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# Signature a primed .seen-* marker must hold so the per-poll signal scan does
# not fire on a pre-existing status (mirrors cs-watch.sh's stat_sig exactly).
seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

# Backdate a file's mtime by ~<secs> seconds (default 500).
backdate() {
  local f=$1 secs=${2:-500} back
  back=$(( $(date +%s) - secs ))
  if [ "$(uname)" = Darwin ]; then
    touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$f"
  else
    touch -m -d "@$back" "$f"
  fi
}

hash_text() {
  if command -v md5 >/dev/null 2>&1; then
    printf '%s' "$1" | md5 -q
  else
    printf '%s' "$1" | md5sum | cut -d' ' -f1
  fi
}

# Prime the stale-detection bookkeeping for <pane> so the NEXT poll is the
# second consecutive identical hash: .hash-<key> holds the capture's hash and
# .count-<key> is 1. Echoes the pane hash.
prime_stale() {  # <state> <pane> <capture-text>
  local state=$1 pane=$2 text=$3 key h
  key=$(printf '%s' "$pane" | tr ':/.' '___')
  h=$(hash_text "$text")
  printf '%s' "$h" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' "$h"
}

pane_key() { printf '%s' "$1" | tr ':/.' '___'; }
