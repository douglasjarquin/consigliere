#!/usr/bin/env bash
# Behavior: cs-update.sh fast-forwards the main repo FF-only (never forced,
# never on a dirty tree or diverged/tangled branch), reports instruction
# rereads only when loaded surfaces changed, and delegates the capo sweep.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(cs_test_tmproot cs-update)
cs_git_identity

# Fixture: an "origin" consigliere and a cloned running copy with the script
# tree present (cs-update resolves CS_ROOT from CS_ROOT_OVERRIDE).
mk_fixture() { # <name> -> sets ORIGIN, CLONE
  local name=$1
  ORIGIN="$TMP/$name-origin"
  CLONE="$TMP/$name-clone"
  mkdir -p "$ORIGIN"
  git -C "$ORIGIN" init -qb main
  mkdir -p "$ORIGIN/bin" "$ORIGIN/skills"
  echo '# contract v1' > "$ORIGIN/AGENTS.md"
  echo 'v1' > "$ORIGIN/bin/tool.sh"
  echo 'readme' > "$ORIGIN/README.md"
  git -C "$ORIGIN" add -A
  git -C "$ORIGIN" commit -qm v1
  git clone -q "$ORIGIN" "$CLONE"
  mkdir -p "$CLONE/state" "$CLONE/data"
  # cs-update runs cs-guard.sh from its own script dir; give the clone a stub.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CLONE/bin/cs-guard.sh"
  chmod +x "$CLONE/bin/cs-guard.sh"
  cp "$ROOT/bin/cs-update.sh" "$CLONE/bin/cs-update.sh"
  # cs-update sources the root/home resolver from its own script dir.
  cp "$ROOT/bin/cs-root-lib.sh" "$CLONE/bin/cs-root-lib.sh"
}

run_update() { # <clone>
  CS_ROOT_OVERRIDE="$1" CS_HOME="$1" bash "$1/bin/cs-update.sh" 2>&1
}

# 1. already current
mk_fixture cur
out=$(run_update "$CLONE")
assert_contains "$out" "already current" "no-op update reports current"
assert_contains "$out" "reread-consigliere: no" "no reread when nothing changed"
pass "already-current no-op"

# 2. instruction change -> updated + reread yes
mk_fixture instr
echo '# contract v2' > "$ORIGIN/AGENTS.md"
git -C "$ORIGIN" commit -qam v2
out=$(run_update "$CLONE")
assert_contains "$out" "consigliere: updated" "FF applied"
assert_contains "$out" "reread-consigliere: yes" "AGENTS.md change demands reread"
assert_grep 'contract v2' "$CLONE/AGENTS.md" "clone actually advanced"
pass "instruction FF triggers reread"

# 3. non-instruction change -> updated + reread no
mk_fixture doc
echo 'more' >> "$ORIGIN/README.md"
git -C "$ORIGIN" commit -qam docs
out=$(run_update "$CLONE")
assert_contains "$out" "consigliere: updated" "FF applied"
assert_contains "$out" "reread-consigliere: no" "README change needs no reread"
pass "non-instruction FF skips reread"

# 4. tracked modifications refuse; untracked files never block
mk_fixture dirty
echo '# contract v2' > "$ORIGIN/AGENTS.md"
git -C "$ORIGIN" commit -qam v2
echo modified > "$CLONE/README.md"
out=$(run_update "$CLONE")
assert_contains "$out" "tracked modifications" "tracked change never updated over"
assert_grep 'contract v1' "$CLONE/AGENTS.md" "clone unchanged"
git -C "$CLONE" checkout -q README.md
echo scratch > "$CLONE/scratch.txt"
out=$(run_update "$CLONE")
assert_contains "$out" "consigliere: updated" "untracked file does not block FF"
pass "tracked-dirty skips; untracked never blocks"

# 5. diverged local refuses (never forced)
mk_fixture div
echo '# contract v2' > "$ORIGIN/AGENTS.md"
git -C "$ORIGIN" commit -qam v2
echo 'local divergence' > "$CLONE/local.txt"
git -C "$CLONE" add local.txt
git -C "$CLONE" commit -qm local
out=$(run_update "$CLONE")
assert_contains "$out" "skipped (local default branch has diverged" "diverged never forced"
pass "diverged branch skips"

# 6. tangled checkout (non-default branch) refuses
mk_fixture tangle
git -C "$CLONE" checkout -qb feature
out=$(run_update "$CLONE")
assert_contains "$out" "not default branch" "tangle skips update"
pass "tangled checkout skips"

pass "cs-update behaviors"
