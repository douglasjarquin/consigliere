#!/usr/bin/env bash
# End-to-end demonstration of the herdr plugin event transport (S5).
#
# Runs the REAL bin/cs-watch.sh watcher, the REAL bin/cs-herdr-event-hook.sh
# (invoked exactly the way herdr's server invokes it: HERDR_PLUGIN_EVENT +
# HERDR_PLUGIN_EVENT_JSON in the environment, the home's state dir as argv), and
# the REAL bin/cs-herdr-event-plugin.sh installer against a fake `herdr` CLI so
# nothing touches this machine's global herdr plugin registry.
#
# The payload string is the one recorded live from herdr 0.8.0 in docs/herdr.md.
set -u
ROOT=${1:?usage: e2e-herdr-event-transport.sh <repo-root>}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cs-s5-e2e.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

hr() { printf '\n=== %s ===\n' "$1"; }

# --- fake herdr: plugin registry + the pane/agent reads the watcher makes ----
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${CS_FAKE_HERDR_LOG:-/dev/null}"
case "${1:-} ${2:-}" in
  "plugin list")
    printf '{"result":{"plugins":[' ; sep=""
    while IFS=$'\t' read -r pid path; do
      printf '%s{"plugin_id":"%s","manifest_path":"%s","enabled":true}' "$sep" "$pid" "$path"; sep=","
    done < "${CS_FAKE_HERDR_REGISTRY:-/dev/null}" 2>/dev/null
    printf ']}}\n'; exit 0 ;;
  "plugin link")
    manifest="${3:-}/herdr-plugin.toml"
    pid=$(sed -n 's/^id = "\(.*\)"/\1/p' "$manifest" 2>/dev/null)
    printf '%s\t%s\n' "$pid" "$manifest" >> "${CS_FAKE_HERDR_REGISTRY:-/dev/null}"
    printf '{"result":{"type":"plugin_linked"}}\n'; exit 0 ;;
  "plugin unlink")
    if [ -n "${CS_FAKE_HERDR_REGISTRY:-}" ] && [ -f "$CS_FAKE_HERDR_REGISTRY" ]; then
      grep -v "^${3:-}	" "$CS_FAKE_HERDR_REGISTRY" > "$CS_FAKE_HERDR_REGISTRY.tmp" || true
      mv "$CS_FAKE_HERDR_REGISTRY.tmp" "$CS_FAKE_HERDR_REGISTRY"
    fi
    printf '{"result":{"type":"plugin_unlinked"}}\n'; exit 0 ;;
  "api snapshot") exit 1 ;;
  "pane read") [ -z "${CS_FAKE_HERDR_CAPTURE:-}" ] || cat "$CS_FAKE_HERDR_CAPTURE"; exit 0 ;;
  "agent get")
    printf '{"result":{"agent":{"agent":"claude","agent_status":"%s"}}}\n' \
      "${CS_FAKE_HERDR_AGENT_STATUS:-idle}"; exit 0 ;;
  "status --json") printf '{"server":{"protocol":19},"client":{"protocol":19}}\n'; exit 0 ;;
esac
exit 1
SH
chmod +x "$FAKEBIN/herdr"
cat > "$FAKEBIN/cs-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: unknown · source: none · e2e fake\n'
SH
chmod +x "$FAKEBIN/cs-crew-state.sh"

PANE='w7Z:p1'
# Verbatim shape recorded from live herdr 0.8.0 (docs/herdr.md, 2026-08-13).
payload() { # <status>
  printf '{"event":"pane_agent_status_changed","data":{"type":"pane_agent_status_changed","pane_id":"%s","workspace_id":"w7Z","agent_status":"%s","agent":"claude"}}' \
    "$PANE" "$1"
}
seed_home() { # <home>  a home with one recorded soldier pane whose status is already seen
  local home=$1
  mkdir -p "$home/state"
  printf 'pane=%s\nkind=ship\n' "$PANE" > "$home/state/s5-demo.meta"
  printf 'working: implementing the splice\n' > "$home/state/s5-demo.status"
  stat -f '%z:%Fm' "$home/state/s5-demo.status" > "$home/state/.seen-s5-demo_status"
}

run_watch_bg() { # <home> <out> [env...]
  local home=$1 out=$2; shift 2
  env PATH="$FAKEBIN:$PATH" CS_STATE_OVERRIDE="$home/state" \
    CS_CREW_STATE_BIN="$FAKEBIN/cs-crew-state.sh" \
    CS_SIGNAL_GRACE=1 CS_CHECK_INTERVAL=999999 CS_HEARTBEAT=999999 \
    "$@" "$ROOT/bin/cs-watch.sh" > "$out" 2>&1 &
}

wait_for_line() { # <file> <pattern> <deadline-ticks>
  local f=$1 pat=$2 limit=$3 i=0
  while [ "$i" -lt "$limit" ]; do
    grep -qF "$pat" "$f" 2>/dev/null && return 0
    sleep 0.05; i=$((i + 1))
  done
  return 1
}

########################################################################
hr "1. install this home's plugin (fake herdr CLI, no global registry touched)"
HOME_A="$WORK/home-a"; seed_home "$HOME_A"
export CS_FAKE_HERDR_LOG="$WORK/herdr-cli.log"
export CS_FAKE_HERDR_REGISTRY="$WORK/fake-herdr-registry"
: > "$CS_FAKE_HERDR_REGISTRY"
: > "$CS_FAKE_HERDR_LOG"
PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_A" CS_STATE_OVERRIDE="$HOME_A/state" \
  CS_EVENT_PLUGIN_DISABLE=0 "$ROOT/bin/cs-herdr-event-plugin.sh" install
printf -- '--- manifest written to host/herdr-plugin/herdr-plugin.toml ---\n'
cat "$HOME_A/host/herdr-plugin/herdr-plugin.toml"
printf -- '--- herdr CLI calls made by install ---\n'
cat "$CS_FAKE_HERDR_LOG"
printf -- '--- spool (the watcher capability gate) ---\n'
ls -l "$HOME_A/state/.herdr-events"

hr "2. re-install is idempotent, and a second home gets its own plugin id"
: > "$CS_FAKE_HERDR_LOG"
PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_A" CS_STATE_OVERRIDE="$HOME_A/state" \
  CS_EVENT_PLUGIN_DISABLE=0 "$ROOT/bin/cs-herdr-event-plugin.sh" install
printf -- '--- herdr CLI calls on re-install (no second link) ---\n'
cat "$CS_FAKE_HERDR_LOG"
printf -- '--- fake herdr registry after two installs ---\n'
sed 's/\t/  ->  /' "$CS_FAKE_HERDR_REGISTRY"
HOME_B="$WORK/home-b"; seed_home "$HOME_B"
printf 'home A plugin id: %s\n' "$(CS_HOME="$HOME_A" "$ROOT/bin/cs-herdr-event-plugin.sh" id)"
printf 'home B plugin id: %s\n' "$(CS_HOME="$HOME_B" "$ROOT/bin/cs-herdr-event-plugin.sh" id)"

########################################################################
hr "3. FAST PATH: herdr fires the hook, the boss is woken sub-second (poll=60s)"
OUT_A="$WORK/watch-a.out"
export CS_FAKE_HERDR_AGENT_STATUS=working   # poll loop sees a healthy pane
run_watch_bg "$HOME_A" "$OUT_A" CS_POLL=60
WPID=$!
sleep 2   # let the watcher finish its first poll cycle and enter the event wait
printf 'watcher running (pid %s), poll budget 60s, no wake yet: %s\n' \
  "$WPID" "$([ -s "$OUT_A" ] && cat "$OUT_A" || printf '<silent>')"
START=$(python3 -c 'import time; print(time.time())')
printf 'herdr dispatches pane.agent_status_changed(blocked) at t=0\n'
HERDR_PLUGIN_EVENT=pane.agent_status_changed HERDR_PANE_ID=w70:p1 \
  HERDR_PLUGIN_EVENT_JSON="$(payload blocked)" \
  "$ROOT/bin/cs-herdr-event-hook.sh" "$HOME_A/state"
printf -- '--- spool line herdr\x27s hook appended ---\n'
sed 's/\t/<TAB>/g' "$HOME_A/state/.herdr-events"
if wait_for_line "$OUT_A" "stale: $PANE" 200; then
  END=$(python3 -c 'import time; print(time.time())')
  printf 'boss wake latency from event to watcher output: %.2fs (poll budget was 60s)\n' \
    "$(python3 -c "print($END-$START)")"
else
  printf 'FAILED: no wake within 10s\n'
fi
wait "$WPID" 2>/dev/null || true
printf -- '--- watcher stdout (what the boss sees) ---\n'
cat "$OUT_A"
printf -- '--- queued wake ---\n'
cat "$HOME_A"/state/.wake-queue* 2>/dev/null || ls "$HOME_A/state"
printf -- '--- cursor advanced past the consumed record ---\n'
printf 'cursor=%s spool_bytes=%s\n' "$(cat "$HOME_A/state/.herdr-events-cursor")" \
  "$(wc -c < "$HOME_A/state/.herdr-events" | tr -d ' ')"

########################################################################
hr "4. DURABILITY: an edge that fires while NO watcher runs is still delivered"
HOME_C="$WORK/home-c"; seed_home "$HOME_C"
: > "$HOME_C/state/.herdr-events"   # what install does after herdr accepts the link
printf 'no watcher process is running:\n'
pgrep -fl "cs-watch.sh" | grep -F "$WORK" || printf '  (none for this home)\n'
HERDR_PLUGIN_EVENT=pane.agent_status_changed HERDR_PANE_ID=w70:p1 \
  HERDR_PLUGIN_EVENT_JSON="$(payload blocked)" \
  "$ROOT/bin/cs-herdr-event-hook.sh" "$HOME_C/state"
printf 'edge spooled while nothing was listening: %s\n' \
  "$(sed 's/\t/<TAB>/g' "$HOME_C/state/.herdr-events")"
OUT_C="$WORK/watch-c.out"
run_watch_bg "$HOME_C" "$OUT_C" CS_POLL=60
WPID=$!
if wait_for_line "$OUT_C" "stale: $PANE" 300; then
  printf 'the next watcher start drained the backlog and woke the boss:\n'
else
  printf 'FAILED: backlog was not delivered\n'
fi
wait "$WPID" 2>/dev/null || true
cat "$OUT_C"

########################################################################
hr "5. FAIL-OPEN: no plugin on this machine, supervision unchanged"
HOME_D="$WORK/home-d"; seed_home "$HOME_D"
printf 'spool present? %s\n' "$([ -e "$HOME_D/state/.herdr-events" ] && echo yes || echo no)"
export CS_FAKE_HERDR_AGENT_STATUS=blocked   # the poll loop's own level read
OUT_D="$WORK/watch-d.out"
run_watch_bg "$HOME_D" "$OUT_D" CS_POLL=2
WPID=$!
if wait_for_line "$OUT_D" "stale: $PANE" 300; then
  printf 'with no transport at all the poll loop still escalated:\n'
else
  printf 'FAILED: poll-loop backstop did not escalate\n'
fi
wait "$WPID" 2>/dev/null || true
cat "$OUT_D"
unset CS_FAKE_HERDR_AGENT_STATUS

########################################################################
hr "6. uninstall removes the manifest and the capability gate"
: > "$CS_FAKE_HERDR_LOG"
PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_A" CS_STATE_OVERRIDE="$HOME_A/state" \
  CS_EVENT_PLUGIN_DISABLE=0 "$ROOT/bin/cs-herdr-event-plugin.sh" uninstall
cat "$CS_FAKE_HERDR_LOG"
printf 'registry entries after uninstall: %s\n' "$(wc -l < "$CS_FAKE_HERDR_REGISTRY" | tr -d ' ')"
printf 'manifest present? %s   spool present? %s\n' \
  "$([ -e "$HOME_A/host/herdr-plugin/herdr-plugin.toml" ] && echo yes || echo no)" \
  "$([ -e "$HOME_A/state/.herdr-events" ] && echo yes || echo no)"

hr "7. a retired home cannot be rebuilt by a stale registration"
RETIRED="$WORK/retired-home/state"
HERDR_PLUGIN_EVENT=pane.agent_status_changed \
  HERDR_PLUGIN_EVENT_JSON="$(payload blocked)" \
  "$ROOT/bin/cs-herdr-event-hook.sh" "$RETIRED"
printf 'hook exit=%s   retired home recreated? %s\n' "$?" \
  "$([ -e "$WORK/retired-home" ] && echo yes || echo no)"

hr "done"
