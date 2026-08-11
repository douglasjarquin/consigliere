#!/usr/bin/env bash
# Behavior (portable): cs-spawn.sh resolves and persists the root harness, and
# builds the harness-correct launch. A codex root stamps harness=codex and the
# codex notify launch (byte-compatible with before); a claude root stamps
# harness=claude, writes a per-soldier --settings file, and launches claude.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$ROOT/bin/cs-meta-lib.sh"

SPAWN="$ROOT/bin/cs-spawn.sh"
TMP=$(cs_test_tmproot cs-spawn-harness)
FAKEBIN=$(cs_fakebin "$TMP")
cs_git_identity

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "status --json") printf '%s\n' '{"server":{"protocol":16}}' ;;
  "worktree create")
    repo= branch=
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --cwd) repo=$2; shift ;;
        --branch) branch=$2; shift ;;
      esac
      shift
    done
    git -C "$repo" worktree add -q -b "$branch" "$CS_FAKE_SPAWN_WORKTREE"
    printf '{"result":{"workspace":{"workspace_id":"w1"},"root_pane":{"pane_id":"w1:p1"},"worktree":{"path":"%s","branch":"%s"}}}\n' "$CS_FAKE_SPAWN_WORKTREE" "$branch"
    ;;
  "pane run") printf '%s' "${4:-}" > "$CS_FAKE_SPAWN_LAUNCH" ;;
  "agent get")
    # cs-spawn now requires an agent to actually APPEAR after the launch line,
    # because `pane run` reports success even when a not-ready shell swallowed
    # it. CS_FAKE_SPAWN_NO_AGENT=1 reproduces that swallowed launch.
    if [ "${CS_FAKE_SPAWN_NO_AGENT:-0}" = 1 ]; then
      printf '{"result":{"agent":{}}}\n'
    else
      printf '{"result":{"agent":{"agent":"codex","agent_status":"idle"}}}\n'
    fi ;;
  *) printf '{}\n' ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"
printf -- '- project [local-only] - fixture\n' > "$HOME_DIR/config/projects.md"
REPO="$TMP/project"
cs_git_init_commit "$REPO"

# spawn_one drives BOTH ship and scout spawns, and a scout now refuses --mode /
# --yolo, so the ship posture flags are passed per call site rather than here.
spawn_one() {
  local harness=$1 id=$2 wt="$TMP/wt-$2"
  shift 2
  local arg prev='' brief_mode=''
  mkdir -p "$HOME_DIR/data/$id"
  printf 'implement the fixture\n' > "$HOME_DIR/data/$id/brief.md"
  # A ship fixture's brief must record the same delivery contract the spawn
  # passes; a scout's brief carries none. Without this the ship spawns would all
  # exercise the pre-contract compatibility warning instead of the cross-check.
  for arg in "$@"; do
    [ "$prev" = --mode ] && brief_mode=$arg
    prev=$arg
  done
  [ -n "$brief_mode" ] \
    && printf 'Delivery contract: mode=%s\n' "$brief_mode" >> "$HOME_DIR/data/$id/brief.md"
  # CS_CLAUDE_JSON sandboxes the folder-trust pre-seed away from the real
  # ~/.claude.json (claude spawns pre-trust their worktree).
  env PATH="$FAKEBIN:$PATH" CS_HARNESS_OVERRIDE="$harness" \
    CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$HOME_DIR/state" \
    CS_CLAUDE_JSON="$TMP/claude.json" \
    CS_FAKE_SPAWN_WORKTREE="$wt" CS_FAKE_SPAWN_LAUNCH="$TMP/launch-$id" \
    "$SPAWN" "$id" "$REPO" "$@" >/dev/null || fail "spawn ($harness) failed"
  cat "$TMP/launch-$id"
}

# --- codex root: unchanged launch shape, harness=codex ----------------------
launch=$(spawn_one codex t-codex --mode no-mistakes --yolo off)
[ "$(cs_meta_get "$HOME_DIR/state/t-codex.meta" harness)" = codex ] || fail "codex meta harness"
assert_contains "$launch" "codex " "codex root launches codex"
assert_contains "$launch" 'notify=' "codex root wires notify turn-end"
assert_not_contains "$launch" '--settings' "codex root does not use --settings"
assert_absent "$HOME_DIR/state/t-codex.claude-settings.json" "codex root writes no claude settings file"
pass "codex root: harness=codex, codex notify launch, no settings file"

# --- the harness owns model and reasoning level ------------------------------
# Consigliere selects neither, on either harness and for every task kind, so no
# launch may name a model or a reasoning level and no task may record one.
for spec in "codex t-noprofile-codex-ship --mode no-mistakes --yolo off" \
  "codex t-noprofile-codex-scout --scout" \
  "claude t-noprofile-claude-ship --mode no-mistakes --yolo off" \
  "claude t-noprofile-claude-scout --scout"; do
  # shellcheck disable=SC2086
  set -- $spec
  launch=$(spawn_one "$@")
  id=$2
  assert_not_contains "$launch" '--model' "$id launches with no model flag"
  assert_not_contains "$launch" 'model_reasoning_effort' "$id launches with no codex reasoning-effort flag"
  assert_not_contains "$launch" '--effort' "$id launches with no claude effort flag"
  assert_no_grep '^model=' "$HOME_DIR/state/$id.meta" "$id records no model"
  assert_no_grep '^effort=' "$HOME_DIR/state/$id.meta" "$id records no effort"
done
pass "a spawn launches on the harness's own model and reasoning level, and records neither"

# --- --model and --effort are gone, and their absence is LOUD ----------------
# Silently ignoring either would look like consigliere had honoured a choice it
# no longer makes, so both must fail the spawn as unknown flags before anything
# durable exists.
for flag in --model --effort; do
  id="t-refuse${flag}"
  mkdir -p "$HOME_DIR/data/$id"
  printf 'implement the fixture\nDelivery contract: mode=no-mistakes\n' > "$HOME_DIR/data/$id/brief.md"
  if output=$(env PATH="$FAKEBIN:$PATH" CS_HARNESS_OVERRIDE=codex \
    CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$HOME_DIR/state" \
    CS_CLAUDE_JSON="$TMP/claude.json" \
    CS_FAKE_SPAWN_WORKTREE="$TMP/wt-refuse$flag" CS_FAKE_SPAWN_LAUNCH="$TMP/launch-refuse$flag" \
    "$SPAWN" "$id" "$REPO" --mode no-mistakes --yolo off "$flag" high 2>&1); then
    fail "$flag must be refused, not silently ignored"
  fi
  assert_contains "$output" "unknown flag $flag" "$flag is refused by name"
  assert_absent "$HOME_DIR/state/$id.meta" "$flag writes no metadata"
done
pass "--model and --effort are refused as unknown flags"

# --- claude root: --settings launch, harness=claude, settings file written --
launch=$(spawn_one claude t-claude --mode no-mistakes --yolo off)
[ "$(cs_meta_get "$HOME_DIR/state/t-claude.meta" harness)" = claude ] || fail "claude meta harness"
assert_contains "$launch" "claude " "claude root launches claude"
assert_contains "$launch" "--dangerously-skip-permissions" "claude root autonomy flag"
assert_contains "$launch" "--settings" "claude root wires turn-end via --settings"
assert_not_contains "$launch" 'notify=' "claude root does not use codex notify"
SETTINGS="$HOME_DIR/state/t-claude.claude-settings.json"
assert_present "$SETTINGS" "claude root writes a per-soldier settings file"
assert_grep '"Stop"' "$SETTINGS" "claude settings registers a Stop hook"
assert_grep 't-claude.turn-ended' "$SETTINGS" "claude settings touches the turn-end signal"
assert_no_grep 'cs-turnend-guard' "$SETTINGS" "soldier settings must not run the root guard"
# The launch references the settings file by path.
assert_contains "$launch" "$SETTINGS" "claude launch references the settings file"
pass "claude root: harness=claude, --settings launch, settings file written"

# --- config/permission-mode.conf reaches a real spawn ----------------------------
# End-to-end, not just the launch-string unit: proves the home's config dir
# resolves the same way for the harness lib as it does for cs-spawn itself.
printf 'claude auto\n' > "$HOME_DIR/config/permission-mode.conf"
launch=$(spawn_one claude t-claude-permmode --mode no-mistakes --yolo off)
assert_contains "$launch" "--permission-mode 'auto'" "configured permission mode reaches the spawn launch"
assert_not_contains "$launch" '--dangerously-skip-permissions' "configured mode replaces the bypass flag"

printf 'claude plan\n' > "$HOME_DIR/config/permission-mode.conf"
mkdir -p "$HOME_DIR/data/t-permmode-invalid"
printf 'implement the fixture\n' > "$HOME_DIR/data/t-permmode-invalid/brief.md"
if output=$(env PATH="$FAKEBIN:$PATH" CS_HARNESS_OVERRIDE=claude \
  CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$HOME_DIR/state" \
  CS_CLAUDE_JSON="$TMP/claude.json" \
  CS_FAKE_SPAWN_WORKTREE="$TMP/wt-permmode-invalid" CS_FAKE_SPAWN_LAUNCH="$TMP/launch-permmode-invalid" \
  "$SPAWN" t-permmode-invalid "$REPO" --mode no-mistakes --yolo off 2>&1); then
  fail "an unusable permission mode must reject spawn"
fi
assert_contains "$output" "not a usable claude launch permission mode" "unusable mode error is specific"
assert_absent "$HOME_DIR/state/t-permmode-invalid.meta" "unusable mode writes no metadata"
rm -f "$HOME_DIR/config/permission-mode.conf"
pass "config/permission-mode.conf selects the claude launch mode and blocks an unusable one"

# --- the swallowed launch ----------------------------------------------------
# `pane run` hands the launch line to the pane's SHELL and reports success
# whether or not the shell was ready to read it. A freshly created worktree pane
# often is not, and the line is then lost unrecoverably (the same hazard
# tests/cs-herdr-lib-live.test.sh works around by re-submitting an idempotent
# probe). Before this check, cs-spawn printed "spawned", consigliere recorded
# the task as under way, and the pane sat at a bare prompt until the stale timer
# eventually noticed: a soldier that reported success and never existed.
mkdir -p "$HOME_DIR/data/t-swallowed"
printf 'implement the fixture\nDelivery contract: mode=no-mistakes\n' > "$HOME_DIR/data/t-swallowed/brief.md"
if output=$(env PATH="$FAKEBIN:$PATH" CS_HARNESS_OVERRIDE=codex \
  CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$HOME_DIR/state" \
  CS_FAKE_SPAWN_WORKTREE="$TMP/wt-swallowed" CS_FAKE_SPAWN_LAUNCH="$TMP/launch-swallowed" \
  CS_FAKE_SPAWN_NO_AGENT=1 CS_SPAWN_LAUNCH_WAIT_SECS=2 \
  "$SPAWN" t-swallowed "$REPO" --mode no-mistakes --yolo off 2>&1); then
  fail "spawn must fail when no agent appears after the launch"
fi
assert_contains "$output" "no agent appeared" "the swallowed launch must be named, not silently reported as spawned"
assert_not_contains "$output" "spawned t-swallowed" "a swallowed launch must never print a spawn success line"
pass "a launch line the shell swallowed fails loudly instead of reporting a spawn"

# --- optional worker telemetry reaches (only) a real instrumented spawn ------
# The launch artefacts above are the uninstrumented shape, which is the point:
# telemetry is resolved at spawn time, so a soldier launched while telemetry is
# off must be byte identical to one launched before the instrumentation existed.
# docs/telemetry.md owns the contract; this proves it end to end from cs-spawn.
assert_not_contains "$(cat "$TMP/launch-t-codex")" 'cs-telemetry-emit.sh' \
  "telemetry off must add nothing to a codex soldier launch"
[ "$(jq -r '.hooks.Stop[0].hooks | length' "$HOME_DIR/state/t-claude.claude-settings.json")" = 1 ] ||
  fail "telemetry off must leave the claude soldier's Stop hook list at exactly the turn-end touch"
[ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$HOME_DIR/state/t-claude.claude-settings.json")" \
  = "touch $HOME_DIR/state/t-claude.turn-ended" ] ||
  fail "telemetry off must leave the claude soldier's single Stop hook command as the bare turn-end touch"

mkdir -p "$HOME_DIR/host"
printf 'enabled true\n' > "$HOME_DIR/host/telemetry.conf"
export CS_TELEMETRY_DISABLE=''

launch=$(spawn_one codex t-telemetry-codex --mode no-mistakes --yolo off)
assert_contains "$launch" 'touch' "the codex notify command must still touch the turn-end signal"
assert_contains "$launch" 'cs-telemetry-emit.sh' "an enabled home instruments the codex worker turn end"
assert_contains "$launch" '--worker --task' "the worker emitter is called with its task identity"
assert_not_contains "$launch" '--stdin' "codex notify carries no piped payload, so the emitter must not read stdin"
case "$launch" in
  *"touch '$HOME_DIR/state/t-telemetry-codex.turn-ended'; "*) ;;
  *) fail "the turn-end touch must run first, joined by ';' so telemetry cannot gate it: $launch" ;;
esac

launch=$(spawn_one claude t-telemetry-claude --mode no-mistakes --yolo off)
SETTINGS="$HOME_DIR/state/t-telemetry-claude.claude-settings.json"
assert_not_contains "$launch" 'cs-telemetry-emit.sh' \
  "a claude soldier is instrumented through its settings file, not its launch line"
jq -e . "$SETTINGS" >/dev/null || fail "an instrumented claude settings file must stay valid JSON"
[ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$SETTINGS")" \
  = "touch $HOME_DIR/state/t-telemetry-claude.turn-ended" ] ||
  fail "the turn-end touch must remain the first, separate claude Stop hook command"
[ "$(jq -r '.hooks.Stop[0].hooks | length' "$SETTINGS")" = 2 ] ||
  fail "telemetry must be a second hook command, never folded into the touch"
case "$(jq -r '.hooks.Stop[0].hooks[1].command' "$SETTINGS")" in
  *cs-telemetry-emit.sh*--stdin) ;;
  *) fail "claude feeds the Stop payload to every hook command, so the emitter must read it from stdin" ;;
esac

launch=$(spawn_one codex t-telemetry-headless --scout --headless)
assert_not_contains "$launch" 'cs-telemetry-emit.sh' \
  "a headless scout's turn end is process exit; its launch line stays uninstrumented"

unset CS_TELEMETRY_DISABLE
rm -f "$HOME_DIR/host/telemetry.conf"
pass "worker turn-end telemetry is added only when the home enables it, never ahead of the turn-end touch"

pass "cs-spawn harness resolution and launch"
