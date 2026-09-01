#!/usr/bin/env bash
# Portable regression for cs-cursor-lib.sh identity and resolution.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/cs-cursor-lib.sh
. "$ROOT/bin/cs-cursor-lib.sh"
# shellcheck source=bin/cs-harness-lib.sh
. "$ROOT/bin/cs-harness-lib.sh"

TMP_ROOT=$(cs_test_tmproot cs-cursor-lib)
trap 'rm -rf "$TMP_ROOT"' EXIT

make_cursor_tree() {
  local root=$1 ver
  ver="$root/share/cursor-agent/versions/2026.08.11-e8db854"
  mkdir -p "$ver" "$root/bin"
  printf '#!/bin/sh\necho "Start the Cursor Agent"\n' > "$ver/cursor-agent"
  chmod +x "$ver/cursor-agent"
  ln -sf "$ver/cursor-agent" "$root/bin/cursor-agent"
  ln -sf "$ver/cursor-agent" "$root/bin/agent"
  printf '%s' "$root/bin"
}

test_identity_accepts_cursor_shapes() {
  local tree bin
  tree="$TMP_ROOT/tree1"
  bin=$(make_cursor_tree "$tree")
  cs_cursor_process_matches node '' "$bin/cursor-agent" \
    || fail "node + cursor-agent argv0 must identify as cursor"
  cs_cursor_process_matches "$bin/cursor-agent" '' '' \
    || fail "cursor-agent install path must identify"
  ! cs_cursor_process_matches node '' '' \
    || fail "bare node must not identify"
  pass "cs_cursor_process_matches accepts cursor shapes"
}

test_resolve_binary_prefers_stable_path() {
  local tree bin out
  tree="$TMP_ROOT/tree2"
  bin=$(make_cursor_tree "$tree")
  out=$(PATH="$bin:$PATH" cs_cursor_resolve_binary) \
    || fail "resolve must succeed when cursor-agent is on PATH"
  [ "$out" = "$bin/cursor-agent" ] \
    || fail "resolve must print the stable launcher, got '$out'"
  pass "cs_cursor_resolve_binary prints the stable launcher"
}

test_cursor_marker_outranks_claudecode() {
  local out host="$TMP_ROOT/host-empty"
  mkdir -p "$host"
  out=$(
    unset CS_HARNESS_OVERRIDE
    CLAUDECODE=1 CURSOR_AGENT=1 CS_HOST_OVERRIDE="$host" cs_harness_detect_root
  )
  [ "$out" = cursor ] || fail "CURSOR_AGENT must outrank CLAUDECODE, got '$out'"
  out=$(
    unset CS_HARNESS_OVERRIDE CURSOR_AGENT CURSOR_INVOKED_AS
    CLAUDECODE=1 CS_HOST_OVERRIDE="$host" cs_harness_detect_root
  )
  [ "$out" = claude ] || fail "CLAUDECODE alone must detect claude, got '$out'"
  pass "cs_harness_detect_root: cursor marker outranks inherited CLAUDECODE"
}

test_session_sidecar_writes_binding() {
  local state="$TMP_ROOT/state" wt="$TMP_ROOT/wt"
  mkdir -p "$state" "$wt"
  cs_cursor_write_session_sidecar "$state" task1 "$wt"
  assert_grep 'projects_root=' "$state/task1.cursor-session" "sidecar records projects_root"
  assert_grep "workspace_root=$wt" "$state/task1.cursor-session" "sidecar records workspace_root"
  pass "cs_cursor_write_session_sidecar binds workspace"
}

test_identity_accepts_cursor_shapes
test_resolve_binary_prefers_stable_path
test_cursor_marker_outranks_claudecode
test_session_sidecar_writes_binding

pass "cs-cursor-lib"
