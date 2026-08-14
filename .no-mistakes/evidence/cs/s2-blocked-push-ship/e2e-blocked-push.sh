#!/usr/bin/env bash
# End-to-end: the REAL bin/cs-herdr-events.py reader plus the REAL
# cs_watch_wait_transition splice from bin/cs-watch.sh, driven against a
# herdr-shaped AF_UNIX server that honors the agent_status subscription filter
# the way herdr 0.8.0's server does (fake-herdr-server.py).
# No herdr binary, no live herdr session, no agent spawned.
set -u
ROOT=${1:?repo root}
EV=${2:?evidence dir}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cs-e2e.XXXXXX")
STATE="$WORK/state"; mkdir -p "$STATE" "$WORK/bin"
PANE=ws-1:pane-e2e

# Minimal `herdr` stand-in: only the two calls the splice makes outside the
# socket reader - the socket path, and the once-per-cycle poll status.
cat > "$WORK/bin/herdr" <<'FAKE'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "status --json") printf '{"server":{"socket":"%s"}}\n' "$CS_FAKE_HERDR_SOCKET" ;;
  "agent get")     printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$CS_FAKE_HERDR_AGENT_STATUS" ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$WORK/bin/herdr"

run_case() { # <label> <poll-status> <timeout> <status attempts...>
  local label=$1 poll=$2 timeout=$3; shift 3
  local sock="$WORK/$label.sock" cap="$WORK/$label.request.json" rec rc
  HOLD_SECS=$((timeout + 3)) python3 "$EV/fake-herdr-server.py" "$sock" "$cap" "$PANE" "$@" &
  local srv=$!
  while [ ! -e "$sock" ]; do sleep 0.1; done
  rec=$(
    cd "$WORK" || exit 2
    export PATH="$WORK/bin:$PATH" CS_FAKE_HERDR_SOCKET="$sock" CS_FAKE_HERDR_AGENT_STATUS="$poll"
    # shellcheck disable=SC1090,SC1091
    . "$ROOT/bin/cs-watch.sh"
    cs_watch_wait_transition "$timeout" "$STATE" "$PANE"
  ); rc=$?
  kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
  echo "--- case: $label (the once-per-cycle poll sees agent_status=$poll, so any"
  echo "    escalation below can only have come from the pushed, filtered edge) ---"
  echo "  subscribe request actually put on the wire by bin/cs-herdr-events.py:"
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
[print("     ", json.dumps(s)) for s in d["params"]["subscriptions"]]' "$cap"
  sed 's/^/  /' "$cap.log"
  echo "  cs_watch_wait_transition -> rc=$rc  record=$(printf '%s' "$rec" | tr '\t' '|')"
  echo "  escalation markers on disk: $(ls -1A "$STATE" 2>/dev/null | tr '\n' ' ')"
  echo
}

echo "== live substrate: herdr $(herdr --version 2>/dev/null | awk '{print $2}'), protocol $(herdr api schema 2>/dev/null | awk '/^protocol/{print $2}') =="
echo "== pane.agent_status_changed SUBSCRIPTION schema, as published by the installed herdr binary =="
herdr api schema --json | python3 -c 'import json,sys
def walk(o):
    if isinstance(o,dict):
        if o.get("properties",{}).get("type",{}).get("const")=="pane.agent_status_changed":
            print(json.dumps(o)); return True
        return any(walk(v) for v in o.values())
    if isinstance(o,list): return any(walk(v) for v in o)
    return False
walk(json.load(sys.stdin)["schemas"]["request"])'
echo

# 1. a real blocked edge wakes the watcher through the filtered push path
run_case blocked-wakes idle 6 idle blocked

# 2. idle/done only: filtered off the wire entirely, watcher sleeps its whole
#    budget and reports a clean timeout (rc 1) - no spurious wake
run_case noise-stays-off-wire idle 3 idle done idle

# 3. re-arm: the blocked marker from case 1 is still on disk; the still-subscribed
#    working edge clears it so the next blocked escalates again instead of dedup
run_case working-rearms-blocked idle 6 working blocked

rm -rf "$WORK"
