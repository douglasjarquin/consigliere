#!/usr/bin/env bash
# Hermetic tests for Cursor as a consigliere PRIMARY harness adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(cs_test_tmproot cs-cursor-primary)
cs_git_identity

CURSOR_PAYLOAD='{"session_id":"sess-cursor","generation_id":"gen-1","loop_count":0,"status":"completed","hook_event_name":"stop","cursor_version":"2026.08.11-e8db854"}'

test_hook_host_stands_down_claude_payload() {
  # shellcheck source=bin/cs-hook-host-lib.sh
  . "$ROOT/bin/cs-hook-host-lib.sh"
  cs_hook_payload_is_foreign_host "$CURSOR_PAYLOAD" || fail "cursor payload must be foreign to Claude/Codex hooks"
  ! cs_hook_payload_is_foreign_host '{"stop_hook_active":false}' \
    || fail "plain Claude payload must not stand down"
  pass "cs_hook_payload_is_foreign_host detects cursor_version"
}

test_sessionstart_cursor_wraps_digest() {
  local dir="$TMP_ROOT/home"
  mkdir -p "$dir/state" "$dir/config" "$dir/host"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  printf 'codex\n' > "$dir/host/harness.conf"
  out=$(CS_HOME="$dir" CS_ROOT="$dir" CS_STATE_OVERRIDE="$dir/state" \
    "$ROOT/bin/cs-sessionstart-cursor.sh" --source startup 2>/dev/null || true)
  [ -n "$out" ] || pass "sessionstart-cursor may stay silent when lock unavailable"
  case "$out" in
    *additional_context*) pass "sessionstart-cursor returns JSON additional_context when digest runs" ;;
    '') pass "sessionstart-cursor exits quietly when session start is not eligible" ;;
    *) fail "unexpected sessionstart-cursor output: $out" ;;
  esac
}

test_turnend_guard_stands_down_on_cursor_payload() {
  local dir="$TMP_ROOT/guard-home" rc out
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task1.meta"
  rc=0
  printf '%s' "$CURSOR_PAYLOAD" | CS_HOME="$dir" CS_ROOT="$dir" CS_STATE_OVERRIDE="$dir/state" \
    "$ROOT/bin/cs-turnend-guard.sh" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "turnend guard must stand down on cursor payload without --cursor, got rc=$rc"
  rc=0
  out=$(printf '%s' "$CURSOR_PAYLOAD" | CS_HOME="$dir" CS_ROOT="$dir" CS_STATE_OVERRIDE="$dir/state" \
    "$ROOT/bin/cs-turnend-guard.sh" --cursor 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "--cursor must reach the shared block decision, got rc=$rc"
  case "$out" in *'CANNOT SUPERVISE WORK'*) ;; *) fail "expected the shared cursor banner, got: $out" ;; esac
  pass "cs-turnend-guard.sh stands down on cursor-delivered payloads and blocks with --cursor"
}

test_sessionstart_run_stands_down_on_cursor_payload() {
  local dir="$TMP_ROOT/sessionstart-home" out
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  out=$(printf '%s' "$CURSOR_PAYLOAD" | CS_HOME="$dir" CS_ROOT="$dir" CS_STATE_OVERRIDE="$dir/state" \
    "$ROOT/bin/cs-sessionstart-run.sh" 2>&1)
  [ -z "$out" ] || fail "sessionstart-run must stay silent on a cursor duplicate payload: $out"
  pass "cs-sessionstart-run.sh stays inert on cursor payloads"
}

test_hook_host_stands_down_claude_payload
test_sessionstart_cursor_wraps_digest
test_turnend_guard_stands_down_on_cursor_payload
test_sessionstart_run_stands_down_on_cursor_payload

pass "cs-cursor-primary"
