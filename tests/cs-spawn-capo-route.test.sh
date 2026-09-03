#!/usr/bin/env bash
# Behavior (portable): cs-spawn.sh refuses to spawn a ship/scout task for a
# project a registered capo owns unless it runs from that capo's own home or
# carries the explicit --here boss redirect. A refusal happens before any
# worktree, workspace, branch, or metadata exists. A home with no capo registry
# routes nothing; a defective registry refuses rather than routing blind.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/capo-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/capo-helpers.sh"

SPAWN="$ROOT/bin/cs-spawn.sh"
TMP=$(cs_test_tmproot cs-spawn-capo-route)
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
  "pane run") : ;;
  "pane read") printf '\n' ;;
  "agent get") printf '{"result":{"agent":{"agent":"codex","agent_status":"idle"}}}\n' ;;
  *) printf '{}\n' ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

ROOT_HOME="$TMP/root-home"
CAPO_HOME="$TMP/capo-home"
mkdir -p "$ROOT_HOME/data" "$ROOT_HOME/state" "$ROOT_HOME/config" "$ROOT_HOME/host" \
  "$CAPO_HOME/data" "$CAPO_HOME/state" "$CAPO_HOME/config" "$CAPO_HOME/host"
printf -- '- dotfiles [local-only] - fixture\n- unowned [local-only] - fixture\n' | tee "$ROOT_HOME/config/projects.md" > "$CAPO_HOME/config/projects.md"
DOTFILES="$TMP/dotfiles"
UNOWNED="$TMP/unowned"
cs_git_init_commit "$DOTFILES"
cs_git_init_commit "$UNOWNED"
REG_LINE=$(cs_capo_registry_line private 'Private.' "$CAPO_HOME" 'household and machine config' 'rosie, dotfiles')
cs_capo_registry_write "$ROOT_HOME/host/capos.md" "$REG_LINE"
cs_capo_registry_write "$CAPO_HOME/host/capos.md" "$REG_LINE"

# spawn_from <home> <id> <project> [extra flags...] -> combined output; rc kept.
spawn_from() {
  local home=$1 id=$2 proj=$3
  shift 3
  mkdir -p "$home/data/$id"
  printf 'implement the fixture\nDelivery contract: mode=local-only\n' > "$home/data/$id/brief.md"
  env PATH="$FAKEBIN:$PATH" CS_HARNESS_OVERRIDE=codex \
    CS_HOME="$home" CS_DATA_OVERRIDE="$home/data" CS_STATE_OVERRIDE="$home/state" \
    CS_SPAWN_HUMAN_GATE_SECS=0 CS_FAKE_SPAWN_WORKTREE="$TMP/wt-$id" \
    "$SPAWN" "$id" "$proj" --mode local-only --yolo off "$@" 2>&1
}

# --- 1. a capo-owned project refuses from the root home, leaving nothing -----
out=$(spawn_from "$ROOT_HOME" r1 "$DOTFILES"); rc=$?
[ "$rc" -eq 2 ] || fail "a capo-owned project must refuse from another home (rc=$rc): $out"
assert_contains "$out" "belongs to capo private" "the refusal names the owning capo"
assert_contains "$out" "$CAPO_HOME" "the refusal names the capo home to route to"
assert_absent "$ROOT_HOME/state/r1.meta" "a refused spawn records no task"
assert_absent "$TMP/wt-r1" "a refused spawn creates no worktree"
git -C "$DOTFILES" show-ref --verify -q refs/heads/cs/r1 && fail "a refused spawn must create no branch"
pass "a capo-owned project spawned from the root home is refused before anything exists"

# --- 2. --here is the boss redirect and is recorded -------------------------
out=$(spawn_from "$ROOT_HOME" r2 "$DOTFILES" --here) || fail "--here must allow the spawn: $out"
assert_contains "$out" "spawning here on --here" "the override is announced, not silent"
assert_present "$ROOT_HOME/state/r2.meta" "the overridden spawn records its task"
grep -q "^route_override=here$" "$ROOT_HOME/state/r2.meta" || fail "the override must be durable in meta"
pass "--here spawns a capo-owned project from another home and records the override"

# --- 3. the owning capo spawns its own project freely -----------------------
out=$(spawn_from "$CAPO_HOME" c1 "$DOTFILES") || fail "the owning capo must spawn its own project: $out"
assert_not_contains "$out" "belongs to capo" "no routing complaint inside the owning home"
assert_present "$CAPO_HOME/state/c1.meta" "the capo's task is recorded"
grep -q "route_override" "$CAPO_HOME/state/c1.meta" && fail "an in-home spawn records no override"
pass "the owning capo spawns its own project without a routing complaint"

# --- 4. an unowned project spawns from the root home ------------------------
out=$(spawn_from "$ROOT_HOME" r3 "$UNOWNED") || fail "an unowned project must spawn from root: $out"
assert_not_contains "$out" "belongs to capo" "an unowned project has no owner to route to"
pass "a project no capo owns spawns from the root home"

# --- 5. no registry at all routes nothing -----------------------------------
NOREG_HOME="$TMP/noreg-home"
mkdir -p "$NOREG_HOME/data" "$NOREG_HOME/state" "$NOREG_HOME/config"
cp "$ROOT_HOME/config/projects.md" "$NOREG_HOME/config/"
out=$(spawn_from "$NOREG_HOME" n1 "$DOTFILES") || fail "a home with no registry must spawn: $out"
assert_not_contains "$out" "capo routing table" "a missing registry is not a defect"
pass "a home with no capo registry spawns without routing"

# --- 6. a defective registry refuses rather than routing blind ---------------
cs_capo_registry_write "$ROOT_HOME/host/capos.md" "$REG_LINE" '- broken (home: ; scope: nothing)'
out=$(spawn_from "$ROOT_HOME" r4 "$UNOWNED"); rc=$?
[ "$rc" -eq 2 ] || fail "a malformed registry row must refuse the spawn (rc=$rc): $out"
assert_contains "$out" "capo routing table refused" "the refusal is attributed to the registry"
assert_contains "$out" "malformed capo registry entry" "the malformed row is the stated reason"
assert_absent "$ROOT_HOME/state/r4.meta" "a refused spawn records no task"
pass "a malformed capo registry refuses the spawn instead of routing blind"

pass "cs-spawn.sh capo routing gate"
