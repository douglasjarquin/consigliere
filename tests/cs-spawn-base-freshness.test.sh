#!/usr/bin/env bash
# Behavior (portable): cs-spawn.sh refreshes the project clone against origin
# before it creates the task worktree, so a merge this home never saw does not
# silently become the task branch's base. The refresh reuses cs-fleet-sync.sh, so
# it inherits that script's safety rules: nothing is forced, stashed, or
# discarded, and a clone that is off its default branch, dirty, or diverged is
# left exactly as it was. The check is fail-open - an unreachable origin still
# dispatches - but never silent, and an explicit --base skips it entirely.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/cs-spawn.sh"
TMP=$(cs_test_tmproot cs-spawn-base-freshness)
FAKEBIN=$(cs_fakebin "$TMP")
cs_git_identity

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "status --json") printf '%s\n' '{"server":{"protocol":16}}' ;;
  "worktree create")
    repo= branch= base=
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --cwd) repo=$2; shift ;;
        --branch) branch=$2; shift ;;
        --base) base=$2; shift ;;
      esac
      shift
    done
    if [ -n "$base" ]; then
      git -C "$repo" worktree add -q -b "$branch" "$CS_FAKE_SPAWN_WORKTREE" "$base"
    else
      git -C "$repo" worktree add -q -b "$branch" "$CS_FAKE_SPAWN_WORKTREE"
    fi
    printf '{"result":{"workspace":{"workspace_id":"w1"},"root_pane":{"pane_id":"w1:p1"},"worktree":{"path":"%s","branch":"%s"}}}\n' "$CS_FAKE_SPAWN_WORKTREE" "$branch"
    ;;
  "pane run") printf '%s' "${4:-}" > "$CS_FAKE_SPAWN_LAUNCH" ;;
  "agent get") printf '{"result":{"agent":{"agent":"codex","agent_status":"idle"}}}\n' ;;
  *) printf '{}\n' ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"

# One fixture origin, cloned per case so each case gets its own clone state.
UPSTREAM="$TMP/upstream"
SEED="$TMP/seed"
cs_git_init_commit "$SEED"
git clone --quiet --bare "$SEED" "$UPSTREAM"

# upstream_commit <message> - land a commit on the fixture origin's default
# branch, standing in for a merge this home never saw.
upstream_commit() {
  local work="$TMP/upstream-work"
  rm -rf "$work"
  git clone --quiet "$UPSTREAM" "$work"
  printf '%s\n' "$1" >> "$work/README.md"
  git -C "$work" add README.md
  git -C "$work" -c user.name='Consigliere Tests' -c user.email='tests@example.invalid' commit -qm "$1"
  git -C "$work" push --quiet origin HEAD
  rm -rf "$work"
}

# fresh_clone <name> - a clone of the fixture origin under this home's projects
# dir, exactly as cs-project-add.sh would leave it. Echoes its path.
fresh_clone() {
  local dir="$HOME_DIR/projects/$1"
  rm -rf "$dir"
  git clone --quiet "$UPSTREAM" "$dir"
  printf '%s\n' "$dir"
}

# spawn <id> <repo> [flags...] - run a ship spawn, echoing its combined output.
# Never fails the test itself: several cases assert on a spawn that must still
# succeed while warning, and one asserts on the warning text alone.
spawn() {
  local id=$1 repo=$2
  shift 2
  mkdir -p "$HOME_DIR/data/$id"
  printf 'implement the fixture\nDelivery contract: mode=made\n' > "$HOME_DIR/data/$id/brief.md"
  env PATH="$FAKEBIN:$PATH" CS_HARNESS_OVERRIDE=codex \
    CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$HOME_DIR/state" \
    CS_FAKE_SPAWN_WORKTREE="$TMP/wt-$id" CS_FAKE_SPAWN_LAUNCH="$TMP/launch-$id" \
    "$SPAWN" "$id" "$repo" --mode made --yolo off "$@" 2>&1
}

# branch_base <repo> <branch> - the commit the task branch starts from.
branch_base() {
  git -C "$1" rev-parse "$2"
}

# --- a merge this home never saw is picked up before the branch is created ---
# The clone is a full commit behind origin - the state a phone merge, another
# home, or a capo landing work leaves behind. Before this check the task branch
# silently started on the stale commit.
REPO=$(fresh_clone stale)
STALE_HEAD=$(git -C "$REPO" rev-parse HEAD)
upstream_commit "landed elsewhere"
out=$(spawn t-stale "$REPO") || fail "spawn against a stale clone must still succeed"
git -C "$REPO" fetch --quiet origin
FRESH_HEAD=$(git -C "$REPO" rev-parse origin/HEAD)
[ "$STALE_HEAD" != "$FRESH_HEAD" ] || fail "fixture did not actually move origin ahead"
[ "$(branch_base "$REPO" cs/t-stale)" = "$FRESH_HEAD" ] ||
  fail "the task branch must start from the refreshed default branch, not the stale local HEAD"
assert_contains "$out" "refreshed stale from origin before branching" \
  "a base that moved must be reported, not applied silently"
assert_not_contains "$out" "may be behind" "a successful refresh must not warn about staleness"
pass "a spawn against a clone behind origin bases the task branch on the refreshed default branch"

# --- an already-current clone is silent -------------------------------------
REPO=$(fresh_clone current)
out=$(spawn t-current "$REPO") || fail "spawn against a current clone must succeed"
assert_not_contains "$out" "may be behind" "a current clone must not warn"
assert_not_contains "$out" "refreshed current from origin" "a current clone must not claim a refresh"
pass "a clone already current with origin passes the check silently"

# --- --base bypasses the check entirely -------------------------------------
# The named ref is the explicit choice; there is no implicit current-HEAD base to
# keep fresh, so no fetch is attempted at all. Proven by leaving the clone behind
# origin and showing it stays behind.
REPO=$(fresh_clone based)
PINNED=$(git -C "$REPO" rev-parse HEAD)
upstream_commit "landed after the base was pinned"
out=$(spawn t-based "$REPO" --base "$PINNED") || fail "spawn with --base must succeed"
[ "$(branch_base "$REPO" cs/t-based)" = "$PINNED" ] || fail "--base must decide the branch point"
[ "$(git -C "$REPO" rev-parse HEAD)" = "$PINNED" ] ||
  fail "--base must skip the refresh, leaving the clone untouched"
assert_not_contains "$out" "may be behind" "--base must not warn about a base it never checked"
assert_not_contains "$out" "refreshed based from origin" "--base must not refresh the clone"
pass "an explicit --base skips the freshness check"

# --- an unreachable origin dispatches, loudly --------------------------------
# Fail-open: a dead network must never block dispatch. Fail-loud: the spawn must
# say the base could not be confirmed.
REPO=$(fresh_clone unreachable)
git -C "$REPO" remote set-url origin "$TMP/no-such-remote.git"
out=$(spawn t-unreachable "$REPO") || fail "an unreachable origin must not block dispatch"
assert_contains "$out" "could not confirm unreachable is current with origin" \
  "an unreachable origin must be reported"
assert_contains "$out" "may be behind" "the warning must say the base may be stale"
assert_present "$HOME_DIR/state/t-unreachable.meta" "the spawn must still complete"
pass "an unreachable origin proceeds with a loud warning"

# --- a diverged local default branch is left untouched -----------------------
# fleet-sync's STUCK semantics own this: the local commit may be real work, so
# nothing is forced or discarded and the spawn takes the base that exists.
REPO=$(fresh_clone diverged)
printf 'local divergence\n' > "$REPO/local.txt"
git -C "$REPO" add local.txt
git -C "$REPO" -c user.name='Consigliere Tests' -c user.email='tests@example.invalid' \
  commit -qm 'unlanded local work'
DIVERGED_HEAD=$(git -C "$REPO" rev-parse HEAD)
upstream_commit "landed while the clone had diverged"
out=$(spawn t-diverged "$REPO") || fail "a diverged clone must not block dispatch"
[ "$(git -C "$REPO" rev-parse HEAD)" = "$DIVERGED_HEAD" ] ||
  fail "a diverged default branch must be left exactly as it was"
[ "$(branch_base "$REPO" cs/t-diverged)" = "$DIVERGED_HEAD" ] ||
  fail "the task branch must start from the base that exists"
assert_contains "$out" "could not confirm diverged is current with origin" \
  "a stuck clone must be reported"
assert_contains "$out" "STUCK" "the warning must carry fleet-sync's own verdict"
pass "a diverged local default branch is left untouched and reported"

pass "cs-spawn base freshness"
