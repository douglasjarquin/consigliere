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
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state"
printf -- '- project [local-only] - fixture\n' > "$HOME_DIR/data/projects.md"
REPO="$TMP/project"
cs_git_init_commit "$REPO"

# spawn_one <harness> <id> -> echoes the captured launch string; writes meta.
spawn_one() {
  local harness=$1 id=$2 wt="$TMP/wt-$2"
  mkdir -p "$HOME_DIR/data/$id"
  printf 'implement the fixture\n' > "$HOME_DIR/data/$id/brief.md"
  # CS_CLAUDE_JSON sandboxes the folder-trust pre-seed away from the real
  # ~/.claude.json (claude spawns pre-trust their worktree).
  env PATH="$FAKEBIN:$PATH" CS_HARNESS_OVERRIDE="$harness" \
    CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$HOME_DIR/state" \
    CS_CLAUDE_JSON="$TMP/claude.json" \
    CS_FAKE_SPAWN_WORKTREE="$wt" CS_FAKE_SPAWN_LAUNCH="$TMP/launch-$id" \
    "$SPAWN" "$id" "$REPO" >/dev/null || fail "spawn ($harness) failed"
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

pass "cs-spawn harness resolution and launch"
