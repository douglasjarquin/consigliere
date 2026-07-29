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
  *) printf '{}\n' ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"
printf -- '- project [local-only] - fixture\n' > "$HOME_DIR/data/projects.md"
REPO="$TMP/project"
cs_git_init_commit "$REPO"

spawn_one() {
  local harness=$1 id=$2 wt="$TMP/wt-$2"
  shift 2
  mkdir -p "$HOME_DIR/data/$id"
  printf 'implement the fixture\n' > "$HOME_DIR/data/$id/brief.md"
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
launch=$(spawn_one codex t-codex)
[ "$(cs_meta_get "$HOME_DIR/state/t-codex.meta" harness)" = codex ] || fail "codex meta harness"
assert_contains "$launch" "codex " "codex root launches codex"
assert_contains "$launch" 'notify=' "codex root wires notify turn-end"
assert_not_contains "$launch" '--settings' "codex root does not use --settings"
assert_absent "$HOME_DIR/state/t-codex.claude-settings.json" "codex root writes no claude settings file"
pass "codex root: harness=codex, codex notify launch, no settings file"

cat > "$HOME_DIR/config/dispatch-policy" <<'EOF'
# harness kind model effort
codex scout gpt-5.6-sol max
codex ship gpt-5.6-terra ultra
claude scout opus max
claude ship sonnet medium
EOF

launch=$(spawn_one codex t-policy-codex-scout --scout)
[ "$(cs_meta_get "$HOME_DIR/state/t-policy-codex-scout.meta" model)" = gpt-5.6-sol ] || fail "codex scout policy model"
[ "$(cs_meta_get "$HOME_DIR/state/t-policy-codex-scout.meta" effort)" = max ] || fail "codex scout policy effort"
assert_contains "$launch" "--model 'gpt-5.6-sol'" "codex scout policy model launch"
assert_contains "$launch" "-c 'model_reasoning_effort=\"max\"'" "codex scout policy max effort launch"

launch=$(spawn_one codex t-policy-codex-ship)
[ "$(cs_meta_get "$HOME_DIR/state/t-policy-codex-ship.meta" model)" = gpt-5.6-terra ] || fail "codex ship policy model"
[ "$(cs_meta_get "$HOME_DIR/state/t-policy-codex-ship.meta" effort)" = ultra ] || fail "codex ship policy effort"
assert_contains "$launch" "--model 'gpt-5.6-terra'" "codex ship policy model launch"
assert_contains "$launch" "-c 'model_reasoning_effort=\"ultra\"'" "codex ship policy ultra effort launch"

launch=$(spawn_one claude t-policy-claude-scout --scout)
[ "$(cs_meta_get "$HOME_DIR/state/t-policy-claude-scout.meta" model)" = opus ] || fail "claude scout policy model"
[ "$(cs_meta_get "$HOME_DIR/state/t-policy-claude-scout.meta" effort)" = max ] || fail "claude scout policy effort"
assert_contains "$launch" "--model 'opus'" "claude scout policy model launch"
assert_contains "$launch" "--effort 'max'" "claude scout policy effort launch"

launch=$(spawn_one claude t-policy-claude-ship)
[ "$(cs_meta_get "$HOME_DIR/state/t-policy-claude-ship.meta" model)" = sonnet ] || fail "claude ship policy model"
[ "$(cs_meta_get "$HOME_DIR/state/t-policy-claude-ship.meta" effort)" = medium ] || fail "claude ship policy effort"
assert_contains "$launch" "--model 'sonnet'" "claude ship policy model launch"
assert_contains "$launch" "--effort 'medium'" "claude ship policy effort launch"

launch=$(spawn_one codex t-policy-explicit --model gpt-5.6-mini --effort low)
[ "$(cs_meta_get "$HOME_DIR/state/t-policy-explicit.meta" model)" = gpt-5.6-mini ] || fail "explicit model overrides policy"
[ "$(cs_meta_get "$HOME_DIR/state/t-policy-explicit.meta" effort)" = low ] || fail "explicit effort overrides policy"
assert_contains "$launch" "--model 'gpt-5.6-mini'" "explicit model launch"
assert_contains "$launch" "model_reasoning_effort=\"low\"" "explicit effort launch"
pass "dispatch policy selects harness and task-kind profile; explicit flags win"

# --- claude root: --settings launch, harness=claude, settings file written --
launch=$(spawn_one claude t-claude)
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

# --- config/permission-mode reaches a real spawn ----------------------------
# End-to-end, not just the launch-string unit: proves the home's config dir
# resolves the same way for the harness lib as it does for cs-spawn itself.
printf 'claude auto\n' > "$HOME_DIR/config/permission-mode"
launch=$(spawn_one claude t-claude-permmode)
assert_contains "$launch" "--permission-mode 'auto'" "configured permission mode reaches the spawn launch"
assert_not_contains "$launch" '--dangerously-skip-permissions' "configured mode replaces the bypass flag"

printf 'claude plan\n' > "$HOME_DIR/config/permission-mode"
mkdir -p "$HOME_DIR/data/t-permmode-invalid"
printf 'implement the fixture\n' > "$HOME_DIR/data/t-permmode-invalid/brief.md"
if output=$(env PATH="$FAKEBIN:$PATH" CS_HARNESS_OVERRIDE=claude \
  CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$HOME_DIR/state" \
  CS_CLAUDE_JSON="$TMP/claude.json" \
  CS_FAKE_SPAWN_WORKTREE="$TMP/wt-permmode-invalid" CS_FAKE_SPAWN_LAUNCH="$TMP/launch-permmode-invalid" \
  "$SPAWN" t-permmode-invalid "$REPO" 2>&1); then
  fail "an unusable permission mode must reject spawn"
fi
assert_contains "$output" "not a usable claude launch permission mode" "unusable mode error is specific"
assert_absent "$HOME_DIR/state/t-permmode-invalid.meta" "unusable mode writes no metadata"
rm -f "$HOME_DIR/config/permission-mode"
pass "config/permission-mode selects the claude launch mode and blocks an unusable one"

printf 'codex ship gpt-5.6-sol too-much\n' > "$HOME_DIR/config/dispatch-policy"
mkdir -p "$HOME_DIR/data/t-policy-invalid"
printf 'implement the fixture\n' > "$HOME_DIR/data/t-policy-invalid/brief.md"
if output=$(env PATH="$FAKEBIN:$PATH" CS_HARNESS_OVERRIDE=codex \
  CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$HOME_DIR/state" \
  CS_CLAUDE_JSON="$TMP/claude.json" \
  CS_FAKE_SPAWN_WORKTREE="$TMP/wt-policy-invalid" CS_FAKE_SPAWN_LAUNCH="$TMP/launch-policy-invalid" \
  "$SPAWN" t-policy-invalid "$REPO" 2>&1); then
  fail "malformed dispatch policy must reject spawn"
fi
assert_contains "$output" "invalid codex effort 'too-much'" "malformed policy error is specific"
assert_absent "$HOME_DIR/state/t-policy-invalid.meta" "malformed policy writes no metadata"
pass "malformed dispatch policy blocks dispatch"

# --- policy path shapes: a resolving symlink is honored, a dangling one stops -
POLICY="$HOME_DIR/config/dispatch-policy"
rm -f "$POLICY"
printf 'codex ship gpt-5.6-luna high\n' > "$TMP/external-policy"
ln -s "$TMP/external-policy" "$POLICY"
launch=$(spawn_one codex t-policy-symlink)
[ "$(cs_meta_get "$HOME_DIR/state/t-policy-symlink.meta" model)" = gpt-5.6-luna ] || fail "symlinked policy model"
[ "$(cs_meta_get "$HOME_DIR/state/t-policy-symlink.meta" effort)" = high ] || fail "symlinked policy effort"
assert_contains "$launch" "--model 'gpt-5.6-luna'" "symlinked policy model launch"
pass "a dispatch policy symlink resolving to a regular file is honored"

rm -f "$POLICY"
ln -s "$TMP/no-such-policy" "$POLICY"
mkdir -p "$HOME_DIR/data/t-policy-dangling"
printf 'implement the fixture\n' > "$HOME_DIR/data/t-policy-dangling/brief.md"
if output=$(env PATH="$FAKEBIN:$PATH" CS_HARNESS_OVERRIDE=codex \
  CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$HOME_DIR/state" \
  CS_CLAUDE_JSON="$TMP/claude.json" \
  CS_FAKE_SPAWN_WORKTREE="$TMP/wt-policy-dangling" CS_FAKE_SPAWN_LAUNCH="$TMP/launch-policy-dangling" \
  "$SPAWN" t-policy-dangling "$REPO" 2>&1); then
  fail "a dangling dispatch policy symlink must reject spawn"
fi
assert_contains "$output" "dispatch policy symlink does not resolve" "dangling symlink error is specific"
assert_absent "$HOME_DIR/state/t-policy-dangling.meta" "dangling symlink writes no metadata"
rm -f "$POLICY"
pass "a dangling dispatch policy symlink blocks dispatch"

: > "$HOME_DIR/config/dispatch-policy"
mkdir -p "$HOME_DIR/data/t-claude-ultra"
printf 'implement the fixture\n' > "$HOME_DIR/data/t-claude-ultra/brief.md"
if output=$(env PATH="$FAKEBIN:$PATH" CS_HARNESS_OVERRIDE=claude \
  CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$HOME_DIR/state" \
  CS_CLAUDE_JSON="$TMP/claude.json" \
  CS_FAKE_SPAWN_WORKTREE="$TMP/wt-claude-ultra" CS_FAKE_SPAWN_LAUNCH="$TMP/launch-claude-ultra" \
  "$SPAWN" t-claude-ultra "$REPO" --effort ultra 2>&1); then
  fail "claude ultra must reject spawn"
fi
assert_contains "$output" "claude does not accept effort=ultra; choose default|low|medium|high|xhigh|max" "claude ultra error is specific"
assert_absent "$HOME_DIR/state/t-claude-ultra.meta" "claude ultra writes no metadata"
pass "claude ultra blocks dispatch"

pass "cs-spawn harness resolution and launch"
