#!/usr/bin/env bash
# The command herdr's plugin `[[events]]` hook runs, once per event, inside the
# herdr server's process tree. bin/cs-herdr-event-plugin.sh installs the
# manifest that points here and owns the install mechanics.
#
#   cs-herdr-event-hook.sh <state-dir>
#
# herdr supplies the event itself through the environment (verified against
# herdr 0.8.0, docs/herdr.md): HERDR_PLUGIN_EVENT is the kind and
# HERDR_PLUGIN_EVENT_JSON the whole payload. HERDR_PANE_ID is the INVOCATION
# CONTEXT's pane, not the event's, so the pane identity is read from the payload.
#
# This runs on herdr's hot path, so it parses the payload with bash's own regex
# engine: herdr's server may have been started by launchd with a minimal PATH,
# and a hook that needed `jq` there would silently never record anything. The
# fields this transport reads (pane id, workspace id, agent status, agent name)
# are flat scalar tokens, so a full JSON parser buys nothing.
#
# WHAT ONE INVOCATION COSTS. Exactly one external program is exec'd: the `stat`
# in the spool append's rotation check, and even that is optional - if it cannot
# run, the append skips rotation and still records. Everything else is bash
# builtins plus a handful of short-lived subshells for the field extractions:
# this script's own directory and the spool library's platform split are both
# parameter expansion, so a minimal PATH cannot break the hook's bootstrap
# before it ever reaches the payload.
#
# It is SILENT AND SUCCESSFUL on everything it cannot use - an unrelated kind, an
# unparseable payload, a payload with no pane, an unwritable spool, a state
# directory that no longer exists. A hook that failed or blocked would degrade
# herdr itself for every pane on the machine, while a dropped record costs only
# latency: the watcher's poll loop and its level reconcile remain the
# fail-closed backstop.
set -u

[ $# -ge 1 ] || exit 0
STATE=$1
[ -n "$STATE" ] || exit 0
[ "${HERDR_PLUGIN_EVENT:-}" = pane.agent_status_changed ] || exit 0
[ -n "${HERDR_PLUGIN_EVENT_JSON:-}" ] || exit 0

HOOK_DIR=${BASH_SOURCE[0]%/*}
[ "$HOOK_DIR" != "${BASH_SOURCE[0]}" ] || HOOK_DIR=.
# shellcheck source=bin/cs-herdr-event-lib.sh
. "$HOOK_DIR/cs-herdr-event-lib.sh"

# One flat scalar field out of the payload, or empty. Anchored on the quoted key
# so a value that merely LOOKS like a key cannot be mistaken for one.
field() {  # <name>
  [[ $HERDR_PLUGIN_EVENT_JSON =~ \"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}

pane=$(field pane_id) || exit 0
[ -n "$pane" ] || exit 0

generation=
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  [ "$(awk -F= '$1 == "pane" { value=substr($0, 6) } END { print value }' "$meta")" = "$pane" ] || continue
  generation=$(awk -F= '$1 == "endpoint_generation" { value=substr($0, 21) } END { print value }' "$meta")
  break
done
[ -n "$generation" ] || exit 0

cs_event_append "$(cs_event_spool_path "$STATE")" \
  "$(cs_event_record_with_generation status "$pane" "$(field workspace_id || true)" \
      "$(field agent_status || true)" "$(field agent || true)" "$generation")" 2>/dev/null || exit 0
exit 0
