# shellcheck shell=bash
# Shared "which harness delivered this hook payload?" predicate for the tracked
# Claude-shaped and Codex-shaped hook entries.
# Sourced by hook entrypoints; no side effects on source.
#
# Cursor Agent CLI loads `<project>/.claude/settings.json` and
# `<project>/.codex/hooks.json` in addition to its own `<project>/.cursor/hooks.json`
# (verified live, cursor-agent 2026-09-01). A Cursor primary running in a
# consigliere checkout therefore fires BOTH registrations for every event Cursor's
# Claude-compatibility map covers. Consigliere's Cursor registration owns those
# events, so the tracked Claude/Codex entries must stand down.
#
# The signal is the PAYLOAD, not the environment. Cursor exports CURSOR_* into
# children, so an environment guard would also fire inside a Claude session started
# from a Cursor pane. Cursor stamps every hook payload with `cursor_version`.

cs_hook_payload_is_foreign_host() {  # <payload>
  local payload=${1-}
  [ -n "$payload" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  printf '%s' "$payload" | jq -e '
    type == "object" and has("cursor_version") and (.cursor_version | type) == "string"
  ' >/dev/null 2>&1
}
