#!/usr/bin/env bash
# Behavior (portable): the herdr plugin event transport - the server-side
# `[[events]]` hook that carries `pane.agent_status_changed` edges into a home's
# durable spool, replacing the in-watcher socket subscriber.
#
# Covers the three pieces and their fail-open contract:
#   bin/cs-herdr-event-lib.sh     spool record format, atomic append, size cap,
#                                 cursor drain across restarts and truncation
#   bin/cs-herdr-event-hook.sh    the hook herdr executes per event: kind filter,
#                                 payload projection, silence on anything it
#                                 cannot parse
#   bin/cs-herdr-event-plugin.sh  idempotent machine-local install of the per-home
#                                 plugin manifest, status, and uninstall
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(cs_test_tmproot cs-herdr-event-transport)

# tests/lib.sh disables the plugin install for every suite, because herdr's
# registry is global to the user. This suite is the one that exercises install,
# and it does so against a fake herdr that touches nothing real.
CS_EVENT_PLUGIN_DISABLE=0
export CS_EVENT_PLUGIN_DISABLE

LIB="$ROOT/bin/cs-herdr-event-lib.sh"
HOOK="$ROOT/bin/cs-herdr-event-hook.sh"
PLUGIN="$ROOT/bin/cs-herdr-event-plugin.sh"

# shellcheck source=bin/cs-herdr-event-lib.sh
. "$LIB"

status_json() {  # <pane> <workspace> <status> <agent>
  printf '{"event":"pane_agent_status_changed","data":{"type":"pane_agent_status_changed","pane_id":"%s","workspace_id":"%s","agent_status":"%s","agent":"%s"}}' \
    "$1" "$2" "$3" "$4"
}

# --- the spool: append, drain, cursor ---------------------------------------

test_append_and_drain_returns_each_line_once() {
  local dir spool cursor out
  dir=$(mktemp -d "$TMP_ROOT/spool.XXXXXX"); spool="$dir/.herdr-events"; cursor="$dir/.herdr-events-cursor"

  cs_event_append "$spool" "$(cs_event_record status w1:p1 w1 blocked claude)" \
    || fail "appending a record failed"
  out=$(cs_event_drain "$spool" "$cursor") || fail "drain found no new record"
  [ "$out" = "$(printf 'status\tw1:p1\tw1\tblocked\tclaude')" ] \
    || fail "drained record wrong: $out"

  # A second drain with no new appends reports nothing new (rc 1), so a watcher
  # tick never re-escalates an edge it already handled.
  cs_event_drain "$spool" "$cursor" >/dev/null && fail "drain replayed an already-consumed record"

  cs_event_append "$spool" "$(cs_event_record status w1:p1 w1 working claude)"
  out=$(cs_event_drain "$spool" "$cursor") || fail "drain missed the second record"
  [ "$out" = "$(printf 'status\tw1:p1\tw1\tworking\tclaude')" ] \
    || fail "second drained record wrong: $out"
  pass "the spool hands each appended record to the drain exactly once"
}

test_drain_survives_no_reader_and_truncation() {
  local dir spool cursor out lines
  dir=$(mktemp -d "$TMP_ROOT/spool-durable.XXXXXX"); spool="$dir/.herdr-events"; cursor="$dir/.herdr-events-cursor"

  # THE headline gain over the old subscriber: events land while no watcher
  # process exists at all, and the next watcher start drains the backlog.
  cs_event_append "$spool" "$(cs_event_record status w1:p1 w1 working claude)"
  cs_event_append "$spool" "$(cs_event_record status w1:p1 w1 blocked claude)"
  out=$(cs_event_drain "$spool" "$cursor") || fail "a backlog written with no reader did not drain"
  lines=$(printf '%s\n' "$out" | grep -c .)
  [ "$lines" -eq 2 ] || fail "backlog drain returned $lines lines, expected 2"

  # Rotation truncates the spool; a cursor past the new end must reset to the
  # start instead of going permanently silent.
  : > "$spool"
  cs_event_append "$spool" "$(cs_event_record status w2:p1 w2 blocked codex)"
  out=$(cs_event_drain "$spool" "$cursor") || fail "drain went silent after truncation"
  [ "$out" = "$(printf 'status\tw2:p1\tw2\tblocked\tcodex')" ] \
    || fail "post-truncation record wrong: $out"
  pass "the spool survives a watcher gap and a truncation without losing the next edge"
}

test_append_caps_the_spool() {
  local dir spool size
  dir=$(mktemp -d "$TMP_ROOT/spool-cap.XXXXXX"); spool="$dir/.herdr-events"
  CS_EVENT_SPOOL_MAX_BYTES=200
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    cs_event_append "$spool" "$(cs_event_record status "w$i:p1" "w$i" blocked claude)"
  done
  unset CS_EVENT_SPOOL_MAX_BYTES
  size=$(cs_event_file_size "$spool")
  [ "$size" -le 400 ] || fail "spool grew to $size bytes past its cap"
  pass "the spool is size-capped, so an unattended home cannot fill its disk"
}

test_record_fields_never_break_the_line_shape() {
  local rec
  rec=$(cs_event_record status "$(printf 'w1:p1\tx')" w1 "$(printf 'blo\ncked')" claude)
  [ "$(printf '%s' "$rec" | grep -c .)" -eq 1 ] || fail "a record spanned more than one line"
  [ "$(printf '%s' "$rec" | awk -F'\t' '{print NF}')" -eq 5 ] \
    || fail "a record with embedded tabs did not stay 5 fields"
  pass "record fields are sanitized so one event is always exactly one 5-field line"
}

# --- the hook herdr executes -------------------------------------------------

test_hook_projects_a_status_event_into_the_spool() {
  local dir out
  dir=$(mktemp -d "$TMP_ROOT/hook.XXXXXX")
  HERDR_PLUGIN_EVENT=pane.agent_status_changed \
  HERDR_PLUGIN_EVENT_JSON="$(status_json w7Z:p1 w7Z blocked claude)" \
    "$HOOK" "$dir" || fail "the hook exited non-zero on a well-formed event"
  out=$(cat "$dir/.herdr-events")
  [ "$out" = "$(printf 'status\tw7Z:p1\tw7Z\tblocked\tclaude')" ] \
    || fail "hook wrote the wrong record: $out"
  pass "the hook projects a live pane.agent_status_changed payload into the spool"
}

test_hook_is_silent_on_anything_it_cannot_use() {
  local dir
  dir=$(mktemp -d "$TMP_ROOT/hook-quiet.XXXXXX")

  # A kind this transport does not carry.
  HERDR_PLUGIN_EVENT=tab.renamed \
  HERDR_PLUGIN_EVENT_JSON='{"event":"tab_renamed","data":{"tab_id":"w1:t1"}}' \
    "$HOOK" "$dir" || fail "the hook failed on an unrelated event kind"
  # Unparseable payload.
  HERDR_PLUGIN_EVENT=pane.agent_status_changed HERDR_PLUGIN_EVENT_JSON='{not json' \
    "$HOOK" "$dir" || fail "the hook failed on malformed JSON instead of staying silent"
  # A status payload with no pane identity is unusable.
  HERDR_PLUGIN_EVENT=pane.agent_status_changed \
  HERDR_PLUGIN_EVENT_JSON='{"data":{"agent_status":"blocked"}}' \
    "$HOOK" "$dir" || fail "the hook failed on a pane-less payload"
  # No arguments at all: herdr must never see a failing hook.
  "$HOOK" || fail "the hook failed when invoked with no state directory"

  [ ! -s "$dir/.herdr-events" ] || fail "the hook wrote a record it could not use: $(cat "$dir/.herdr-events")"
  pass "the hook stays silent and exits 0 on kinds and payloads it cannot use"
}

# --- the machine-local plugin install ---------------------------------------

# A fake herdr recording every plugin subcommand, so install/uninstall assert
# the exact CLI contract without touching this machine's real plugin registry.
make_fake_herdr() {  # <fakebin> <log>
  local fakebin=$1 log=$2
  mkdir -p "$fakebin"
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$log"
case "\${1:-} \${2:-}" in
  "plugin list")
    if [ -n "\${CS_FAKE_PLUGIN_LINKED:-}" ]; then
      printf '{"result":{"plugins":[{"plugin_id":"%s","manifest_path":"%s","enabled":true}]}}\n' \\
        "\${CS_FAKE_PLUGIN_LINKED}" "\${CS_FAKE_PLUGIN_MANIFEST:-}"
    else
      printf '{"result":{"plugins":[]}}\n'
    fi
    exit 0 ;;
  "plugin link"|"plugin unlink")
    printf '{"result":{"type":"plugin_linked"}}\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/herdr"
}

test_plugin_install_writes_a_machine_local_manifest_and_links_it() {
  local home fakebin log manifest out
  home=$(mktemp -d "$TMP_ROOT/plugin-home.XXXXXX"); mkdir -p "$home/state"
  fakebin="$home/fakebin"; log="$home/herdr.log"
  make_fake_herdr "$fakebin" "$log"

  PATH="$fakebin:$PATH" CS_HOME="$home" CS_STATE_OVERRIDE="$home/state" \
    "$PLUGIN" install >/dev/null || fail "plugin install failed"

  manifest="$home/host/herdr-plugin/herdr-plugin.toml"
  [ -f "$manifest" ] || fail "install wrote no machine-local manifest at $manifest"
  out=$(cat "$manifest")
  assert_contains "$out" 'on = "pane.agent_status_changed"' "manifest subscribes the verified event kind"
  assert_contains "$out" "$ROOT/bin/cs-herdr-event-hook.sh" "manifest runs the hook by absolute path"
  assert_contains "$out" "$home/state" "manifest passes this home's state directory to the hook"
  assert_contains "$(cat "$log")" "plugin link $home/host/herdr-plugin" "install links the manifest directory"
  [ -f "$home/state/.herdr-events" ] || fail "install did not create the spool the watcher gates on"
  pass "install writes a machine-local per-home manifest and links it into herdr"
}

test_plugin_install_is_idempotent() {
  local home fakebin log links
  home=$(mktemp -d "$TMP_ROOT/plugin-idem.XXXXXX"); mkdir -p "$home/state"
  fakebin="$home/fakebin"; log="$home/herdr.log"
  make_fake_herdr "$fakebin" "$log"

  PATH="$fakebin:$PATH" CS_HOME="$home" CS_STATE_OVERRIDE="$home/state" \
    "$PLUGIN" install >/dev/null || fail "first install failed"
  # herdr now reports this home's plugin as already linked from the same manifest.
  CS_FAKE_PLUGIN_LINKED=$(PATH="$fakebin:$PATH" CS_HOME="$home" CS_STATE_OVERRIDE="$home/state" "$PLUGIN" id)
  export CS_FAKE_PLUGIN_LINKED
  CS_FAKE_PLUGIN_MANIFEST="$home/host/herdr-plugin/herdr-plugin.toml"
  export CS_FAKE_PLUGIN_MANIFEST
  : > "$log"
  PATH="$fakebin:$PATH" CS_HOME="$home" CS_STATE_OVERRIDE="$home/state" \
    "$PLUGIN" install >/dev/null || fail "second install failed"
  unset CS_FAKE_PLUGIN_LINKED CS_FAKE_PLUGIN_MANIFEST

  links=$(grep -c "plugin link" "$log" || true)
  [ "$links" -eq 0 ] || fail "an already-installed plugin was re-linked ($links times)"
  pass "install is idempotent: an unchanged, already-linked plugin is left alone"
}

test_plugin_install_fails_open_without_herdr() {
  local home out rc
  home=$(mktemp -d "$TMP_ROOT/plugin-noherdr.XXXXXX"); mkdir -p "$home/state"
  # A stock system PATH: the shell and coreutils this script needs are there,
  # herdr (installed under a package or CI destination prefix) is not.
  out=$(PATH="/usr/bin:/bin" CS_HOME="$home" CS_STATE_OVERRIDE="$home/state" "$PLUGIN" install 2>&1); rc=$?
  expect_code 1 "$rc" "install must report a blocker when herdr is absent"
  assert_contains "$out" "herdr" "the blocker names the missing tool"
  [ ! -e "$home/state/.herdr-events" ] \
    || fail "a failed install left the spool behind, which would gate the watcher onto a dead transport"
  pass "install reports a concrete blocker when herdr is absent, leaving no half-armed transport"
}

test_plugin_uninstall_unlinks_and_removes_the_manifest() {
  local home fakebin log
  home=$(mktemp -d "$TMP_ROOT/plugin-rm.XXXXXX"); mkdir -p "$home/state"
  fakebin="$home/fakebin"; log="$home/herdr.log"
  make_fake_herdr "$fakebin" "$log"
  PATH="$fakebin:$PATH" CS_HOME="$home" CS_STATE_OVERRIDE="$home/state" \
    "$PLUGIN" install >/dev/null || fail "install failed"
  : > "$log"
  PATH="$fakebin:$PATH" CS_HOME="$home" CS_STATE_OVERRIDE="$home/state" \
    "$PLUGIN" uninstall >/dev/null || fail "uninstall failed"
  assert_contains "$(cat "$log")" "plugin unlink" "uninstall unlinks the plugin from herdr"
  [ ! -e "$home/host/herdr-plugin/herdr-plugin.toml" ] || fail "uninstall left the manifest behind"
  [ ! -e "$home/state/.herdr-events" ] \
    || fail "uninstall left the spool behind, so the watcher would still gate onto a removed transport"
  pass "uninstall unlinks the plugin and removes both the manifest and the spool"
}

test_plugin_install_is_disabled_for_test_suites() {
  local home fakebin log out
  home=$(mktemp -d "$TMP_ROOT/plugin-disabled.XXXXXX"); mkdir -p "$home/state"
  fakebin="$home/fakebin"; log="$home/herdr.log"
  make_fake_herdr "$fakebin" "$log"
  out=$(PATH="$fakebin:$PATH" CS_HOME="$home" CS_STATE_OVERRIDE="$home/state" \
    CS_EVENT_PLUGIN_DISABLE=1 "$PLUGIN" install) || fail "a disabled install must still exit 0"
  assert_contains "$out" "disabled" "a disabled install must say so"
  [ ! -e "$log" ] || fail "a disabled install still called herdr: $(cat "$log")"
  [ ! -e "$home/host/herdr-plugin/herdr-plugin.toml" ] || fail "a disabled install wrote a manifest"
  pass "CS_EVENT_PLUGIN_DISABLE keeps a test run out of the user's global herdr registry"
}

test_plugin_id_is_stable_and_home_scoped() {
  local a b other
  a=$(mktemp -d "$TMP_ROOT/plugin-id-a.XXXXXX"); other=$(mktemp -d "$TMP_ROOT/plugin-id-b.XXXXXX")
  local id_a id_a2 id_b
  id_a=$(CS_HOME="$a" "$PLUGIN" id)
  id_a2=$(CS_HOME="$a" "$PLUGIN" id)
  id_b=$(CS_HOME="$other" "$PLUGIN" id)
  [ "$id_a" = "$id_a2" ] || fail "the plugin id is not stable across runs: $id_a vs $id_a2"
  [ "$id_a" != "$id_b" ] || fail "two homes collided on the same plugin id: $id_a"
  b=$(printf '%s' "$id_a" | grep -c '^consigliere-events-[0-9a-f]\{8\}$') || b=0
  [ "$b" -eq 1 ] || fail "unexpected plugin id shape: $id_a"
  pass "each home gets its own stable plugin id, so capo homes never overwrite each other"
}

test_append_and_drain_returns_each_line_once
test_drain_survives_no_reader_and_truncation
test_append_caps_the_spool
test_record_fields_never_break_the_line_shape
test_hook_projects_a_status_event_into_the_spool
test_hook_is_silent_on_anything_it_cannot_use
test_plugin_install_writes_a_machine_local_manifest_and_links_it
test_plugin_install_is_idempotent
test_plugin_install_fails_open_without_herdr
test_plugin_uninstall_unlinks_and_removes_the_manifest
test_plugin_install_is_disabled_for_test_suites
test_plugin_id_is_stable_and_home_scoped
