#!/usr/bin/env bash
# Install this home's herdr event-transport plugin: the server-side
# `[[events]]` hook that pushes `pane.agent_status_changed` edges into
# state/.herdr-events for the watcher to drain (bin/cs-herdr-event-lib.sh owns
# the spool contract).
#
#   cs-herdr-event-plugin.sh install      write the manifest and link it (idempotent)
#   cs-herdr-event-plugin.sh uninstall    unlink it and remove the manifest and spool
#   cs-herdr-event-plugin.sh status       report installed/absent for this home
#   cs-herdr-event-plugin.sh id           print this home's plugin id
#
# MACHINE-LOCAL, PER HOME. herdr's plugin registry is global to the user
# (herdr 0.7.3+), so the manifest lives under this home's machine-local
# `host/herdr-plugin/` and its id carries a digest of the home path. Two homes on
# one machine - the main home and each capo - install side by side and each
# receives every pane's edges into its own spool; a home's watcher filters to its
# own recorded panes on drain. `host/` is never backed up or propagated, so a new
# machine installs fresh, which is exactly right for a registry that lives in
# ~/.config/herdr.
#
# IDEMPOTENT. Re-running install rewrites the manifest only when its content
# changed and links only when herdr does not already report this id from this
# manifest path, so bin/cs-bootstrap.sh can call it at every session start.
#
# CS_EVENT_PLUGIN_DISABLE=1 makes install and uninstall no-ops that report
# `disabled`. herdr's plugin registry is global to the user, so any test that
# runs a session start with a real herdr on PATH would otherwise register a
# plugin for its throwaway home; tests/lib.sh sets this for every suite.
#
# FAIL-OPEN BY CONSTRUCTION. The spool file doubles as the watcher's capability
# gate, and it is created only after herdr accepts the link: a machine without
# this plugin (or a failed install) leaves no spool, the watcher keeps its poll
# loop, and supervision is unchanged apart from blocked-escalation latency.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
# shellcheck source=bin/cs-herdr-event-lib.sh
. "$SCRIPT_DIR/cs-herdr-event-lib.sh"

PLUGIN_DIR="$HOST_DIR/herdr-plugin"
MANIFEST="$PLUGIN_DIR/herdr-plugin.toml"
HOOK="$SCRIPT_DIR/cs-herdr-event-hook.sh"
SPOOL=$(cs_event_spool_path "$STATE")

die() {
  printf 'cs-herdr-event-plugin: %s\n' "$1" >&2
  exit 1
}

home_digest() {
  local hash
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$CS_HOME" | shasum -a 256 | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$CS_HOME" | sha256sum | awk '{print $1}')
  else
    die "shasum or sha256sum is required to derive this home's plugin id"
  fi
  printf '%s' "${hash:0:8}"
}

plugin_id() {
  printf 'consigliere-events-%s' "$(home_digest)"
}

manifest_text() {  # <plugin-id>
  cat <<EOF
id = "$1"
name = "Consigliere event transport ($CS_HOME)"
version = "1"
min_herdr_version = "0.8.0"

[[events]]
on = "pane.agent_status_changed"
command = ["$HOOK", "$STATE"]
EOF
}

# 0 when herdr already reports <plugin-id> linked from THIS home's manifest.
# Any other answer (a different manifest path, an unreadable registry) is
# treated as not-installed, so install re-links rather than trusting a stale or
# foreign registration.
already_linked() {  # <plugin-id>
  local id=$1 listed
  listed=$(herdr plugin list --json 2>/dev/null) || return 1
  printf '%s' "$listed" | jq -e --arg id "$id" --arg path "$MANIFEST" \
    '.result.plugins[]? | select(.plugin_id == $id and .manifest_path == $path)' >/dev/null 2>&1
}

cmd_install() {
  local id current desired
  if [ "${CS_EVENT_PLUGIN_DISABLE:-}" = 1 ]; then
    printf 'disabled\n'
    return 0
  fi
  command -v herdr >/dev/null 2>&1 || die "herdr is required to install the event transport plugin"
  command -v jq >/dev/null 2>&1 || die "jq is required to install the event transport plugin"
  [ -x "$HOOK" ] || die "event hook $HOOK is missing or not executable"
  id=$(plugin_id)
  desired=$(manifest_text "$id")
  mkdir -p "$PLUGIN_DIR" || die "cannot create $PLUGIN_DIR"
  current=$(cat "$MANIFEST" 2>/dev/null) || current=
  if [ "$current" != "$desired" ]; then
    printf '%s\n' "$desired" > "$MANIFEST" || die "cannot write $MANIFEST"
  elif already_linked "$id"; then
    printf 'installed %s\n' "$id"
    return 0
  fi
  herdr plugin link "$PLUGIN_DIR" >/dev/null 2>&1 \
    || die "herdr refused to link $PLUGIN_DIR"
  mkdir -p "$STATE" || die "cannot create $STATE"
  [ -e "$SPOOL" ] || : > "$SPOOL" || die "cannot create $SPOOL"
  printf 'installed %s\n' "$id"
}

cmd_uninstall() {
  local id
  if [ "${CS_EVENT_PLUGIN_DISABLE:-}" = 1 ]; then
    printf 'disabled\n'
    return 0
  fi
  id=$(plugin_id)
  if command -v herdr >/dev/null 2>&1; then
    herdr plugin unlink "$id" >/dev/null 2>&1 || true
  fi
  rm -f "$MANIFEST" 2>/dev/null || true
  rmdir "$PLUGIN_DIR" 2>/dev/null || true
  rm -f "$SPOOL" "$(cs_event_cursor_path "$STATE")" 2>/dev/null || true
  printf 'removed %s\n' "$id"
}

cmd_status() {
  local id
  id=$(plugin_id)
  if [ -f "$MANIFEST" ] && [ -e "$SPOOL" ] && already_linked "$id"; then
    printf 'installed %s\n' "$id"
    return 0
  fi
  printf 'absent %s\n' "$id"
  return 1
}

case "${1:-}" in
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  status)    cmd_status ;;
  id)        plugin_id; printf '\n' ;;
  *)         die "usage: cs-herdr-event-plugin.sh <install|uninstall|status|id>" ;;
esac
