#!/usr/bin/env bash
# End-to-end at the surface a human actually sees: the REAL bin/cs-watch.sh
# watcher process, with its native event splice ENABLED, escalating a soldier
# that went `blocked` - reached ONLY through herdr's pushed, server-filtered
# agent_status edge.
#
# The fake herdr CLI below answers every LEVEL read with agent_status=idle, so
# the poll backstop can never produce this escalation; the only path to the wake
# line printed at the end is the filtered pane.agent_status_changed push.
set -u
ROOT=${1:?repo root}
EV=${2:?evidence dir}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cs-e2e-watch.XXXXXX")
STATE="$WORK/state"; FAKEBIN="$WORK/bin"; mkdir -p "$STATE" "$FAKEBIN"
PANE=pane-push-1
SOCK="$WORK/herdr.sock"

cat > "$FAKEBIN/herdr" <<'FAKE'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "status --json") printf '{"server":{"protocol":19,"socket":"%s"},"client":{"protocol":19}}\n' "$CS_FAKE_HERDR_SOCKET"; exit 0 ;;
  "api snapshot")  exit 1 ;;
  "pane read")     printf 'working on it\n'; exit 0 ;;
  "agent get")     printf '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}\n'; exit 0 ;;
esac
exit 1
FAKE
cat > "$FAKEBIN/cs-crew-state.sh" <<'FAKE'
#!/usr/bin/env bash
printf 'state: working · source: run-step · validating (running)\n'
FAKE
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/cs-crew-state.sh"

# One recorded soldier, mid-task, nothing boss-relevant in its status log.
printf 'pane=%s\nkind=ship\n' "$PANE" > "$STATE/ship.meta"
printf 'working: implementing\n' > "$STATE/ship.status"

# herdr-shaped server: honors the agent_status filter, pushes ONE blocked edge.
HOLD_SECS=20 python3 "$EV/fake-herdr-server.py" "$SOCK" "$WORK/request.json" "$PANE" idle blocked &
srv=$!
while [ ! -e "$SOCK" ]; do sleep 0.1; done

echo "== the real watcher, event splice on, every LEVEL read answering idle =="
env PATH="$FAKEBIN:$PATH" CS_STATE_OVERRIDE="$STATE" \
  CS_CREW_STATE_BIN="$FAKEBIN/cs-crew-state.sh" \
  CS_FAKE_HERDR_SOCKET="$SOCK" CS_HERDR_EVENTS_FORCE=1 \
  CS_POLL=10 CS_SIGNAL_GRACE=1 CS_CHECK_INTERVAL=999999 CS_HEARTBEAT=999999 \
  "$ROOT/bin/cs-watch.sh" > "$WORK/watch.out" 2>"$WORK/watch.err"
rc=$?
kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null

echo "-- what the server put on / kept off the wire --"
sed 's/^/   /' "$WORK/request.json.log"
echo "-- watcher exit code: $rc"
echo "-- wake reason printed to the supervisor (this is the boss-facing line) --"
sed 's/^/   /' "$WORK/watch.out"
echo "-- durable wake queue record (epoch, seq, kind, key, payload) --"
sed 's/^/   /' "$STATE/.wake-queue" 2>/dev/null
echo "-- dedupe marker committed for the pane --"
ls -1A "$STATE" | grep herdr-escalated | sed 's/^/   /'
rm -rf "$WORK"
