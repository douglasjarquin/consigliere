#!/usr/bin/env bash
# Behavior (portable): cs-spawn.sh reports a launched agent that is waiting on a
# HUMAN instead of letting it read as an ordinary successful spawn. An agent
# parked on the harness directory-trust prompt is present, alive, and permanently
# stopped, so the agent-presence gate alone cannot tell it apart from one that is
# working - this is the check that can.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/cs-spawn.sh"
TMP=$(cs_test_tmproot cs-spawn-human-gate)
FAKEBIN=$(cs_fakebin "$TMP")
cs_git_identity

# CS_FAKE_AGENT_STATUS drives herdr's native agent state and CS_FAKE_PANE_TEXT
# drives what the pane renders, so the two halves of the report - the state that
# detects the block and the text that names its cause - are exercised separately.
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
  "pane run") : ;;
  "pane read") printf '%s\n' "${CS_FAKE_PANE_TEXT:-}" ;;
  "agent get")
    printf '{"result":{"agent":{"agent":"codex","agent_status":"%s"}}}\n' "${CS_FAKE_AGENT_STATUS:-idle}" ;;
  *) printf '{}\n' ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"
printf -- '- project [local-only] - fixture\n' > "$HOME_DIR/config/projects.md"
REPO="$TMP/project"
cs_git_init_commit "$REPO"

TRUST_SCREEN='Do you trust the contents of this directory?
1. Yes, continue
2. No, quit'

# spawn_one <id> <agent-status> <pane-text> -> stderr, with stdout dropped.
# CS_SPAWN_HUMAN_GATE_SECS=0 keeps the settle window to a single read so the
# portable suite never sleeps for it.
spawn_one() {
  local id=$1 status=$2 text=$3
  mkdir -p "$HOME_DIR/data/$id"
  printf 'implement the fixture\nDelivery contract: mode=local-only\n' > "$HOME_DIR/data/$id/brief.md"
  { env PATH="$FAKEBIN:$PATH" CS_HARNESS_OVERRIDE=codex \
    CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$HOME_DIR/state" \
    CS_SPAWN_HUMAN_GATE_SECS=0 \
    CS_FAKE_AGENT_STATUS="$status" CS_FAKE_PANE_TEXT="$text" \
    CS_FAKE_SPAWN_WORKTREE="$TMP/wt-$id" \
    "$SPAWN" "$id" "$REPO" --mode local-only --yolo off >/dev/null; } 2>&1
}

out=$(spawn_one gate1 blocked "$TRUST_SCREEN") || fail "a blocked agent must not fail the spawn: $out"
assert_contains "$out" "waiting on a human" "a blocked agent is reported, not passed off as a working one"
assert_contains "$out" "directory-trust prompt" "the report names the concrete cause it can see on the pane"
assert_present "$HOME_DIR/state/gate1.meta" "the task record survives: the block clears with one keystroke"
pass "a launched agent parked on the trust prompt is reported with its cause"

out=$(spawn_one gate2 blocked 'Working on it') || fail "spawn failed: $out"
assert_contains "$out" "waiting on a human" "a blocked agent is reported whatever the pane renders"
assert_not_contains "$out" "directory-trust prompt" "an unrecognized pane is not attributed to the trust prompt"
pass "a blocked agent with no trust prompt on screen is reported without inventing a cause"

out=$(spawn_one gate3 idle "$TRUST_SCREEN") || fail "spawn failed: $out"
assert_not_contains "$out" "waiting on a human" "a non-blocked agent is never reported as human-gated"
pass "an agent that is not blocked produces no report, whatever text is on the pane"

out=$(spawn_one gate4 working "$TRUST_SCREEN") || fail "spawn failed: $out"
assert_not_contains "$out" "waiting on a human" "a working agent is never reported as human-gated"
pass "a working agent produces no report"

pass "cs-spawn human-gate reporting"
