#!/usr/bin/env bash
# tests/cs-migrate-config.test.sh - the config/ layout migrator and the
# fail-closed layout gate (bin/cs-migrate-config.sh + cs_layout_gate in
# bin/cs-root-lib.sh). Asserts: old-name files move to their config/ homes by
# rename with symlinks preserved intact; the run is idempotent; a re-created
# old-name symlink with the same target is absorbed; divergent old+new content
# refuses and names both paths; the gate refuses every ordinary script while
# any old name exists and passes once migrated; and CS_LAYOUT_GATE_SKIP=1 is
# honored.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MIGRATE="$ROOT/bin/cs-migrate-config.sh"

TMP_ROOT=$(cs_test_tmproot cs-migrate-config)
HOME_DIR="$TMP_ROOT/home"
DOTFILES="$TMP_ROOT/dotfiles"

reset_home() {
  rm -rf "$HOME_DIR"
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/config" "$DOTFILES"
}

run_migrate() {
  RC=0
  OUT=$(CS_HOME="$HOME_DIR" "$MIGRATE" 2>&1) || RC=$?
}

gate_probe() {  # run a gated script against the home; cs-lock is the cheapest
  RC=0
  OUT=$(CS_HOME="$HOME_DIR" CS_STATE_OVERRIDE="$HOME_DIR/state" \
    bash -c '. "'"$ROOT"'/bin/cs-root-lib.sh"; cs_resolve_root' 2>&1) || RC=$?
}

# --- the move: regular files, symlinks preserved, host tier -------------------

test_migrates_and_preserves_symlinks() {
  reset_home
  printf 'the boss\n' > "$DOTFILES/boss.md"
  ln -s "$DOTFILES/boss.md" "$HOME_DIR/data/boss.md"
  printf 'learned things\n' > "$HOME_DIR/data/learnings.md"
  printf 'claude auto\n' > "$HOME_DIR/config/permission-mode"
  printf '%s\n' '- cap (home: /x; scope: y)' > "$HOME_DIR/data/capos.md"

  run_migrate
  expect_code 0 "$RC" "migration run"

  [ -L "$HOME_DIR/config/boss.md" ] || fail "boss.md symlink was not preserved by the move"
  [ "$(readlink "$HOME_DIR/config/boss.md")" = "$DOTFILES/boss.md" ] \
    || fail "boss.md symlink target changed"
  [ "$(cat "$HOME_DIR/config/learnings.md")" = "learned things" ] || fail "learnings.md content lost"
  [ "$(cat "$HOME_DIR/config/host/permission-mode.conf")" = "claude auto" ] \
    || fail "permission-mode did not land in config/host/ with its .conf name"
  [ -f "$HOME_DIR/config/host/capos.md" ] || fail "capos.md did not land in config/host/"
  [ ! -e "$HOME_DIR/data/boss.md" ] || fail "old boss.md path still exists"
  [ ! -e "$HOME_DIR/config/permission-mode" ] || fail "old permission-mode path still exists"
  pass "old names move to config/ and config/host/ with symlinks intact"
}

# --- idempotence and the nix re-link absorption --------------------------------

test_idempotent_and_absorbs_recreated_link() {
  run_migrate
  expect_code 0 "$RC" "second run"
  [ -z "$OUT" ] || fail "a converged home must be a quiet no-op, got: $OUT"

  # A dotfiles manager (nix ln -sfn) re-creates the OLD name with the SAME
  # target after migration; the migrator absorbs it instead of refusing.
  ln -s "$DOTFILES/boss.md" "$HOME_DIR/data/boss.md"
  run_migrate
  expect_code 0 "$RC" "re-created same-target link run"
  [ ! -e "$HOME_DIR/data/boss.md" ] && [ ! -L "$HOME_DIR/data/boss.md" ] \
    || fail "re-created old-name symlink was not absorbed"
  [ -L "$HOME_DIR/config/boss.md" ] || fail "new-name symlink was disturbed"
  pass "idempotent, and a re-created same-target old link is absorbed"
}

# --- divergent old+new refuses --------------------------------------------------

test_divergent_content_refuses() {
  printf 'old queue\n' > "$HOME_DIR/data/backlog.md"
  printf 'new queue\n' > "$HOME_DIR/config/backlog.md"
  run_migrate
  expect_code 1 "$RC" "divergent old+new must refuse"
  assert_contains "$OUT" "REFUSED" "refusal marker missing"
  assert_contains "$OUT" "data/backlog.md" "refusal must name the old path"
  assert_contains "$OUT" "config/backlog.md" "refusal must name the new path"
  [ "$(cat "$HOME_DIR/data/backlog.md")" = "old queue" ] || fail "old content touched on refusal"
  [ "$(cat "$HOME_DIR/config/backlog.md")" = "new queue" ] || fail "new content touched on refusal"
  rm "$HOME_DIR/data/backlog.md"
  pass "divergent old+new content refuses, names both paths, touches neither"
}

# --- the fail-closed gate --------------------------------------------------------

test_layout_gate() {
  printf 'x\n' > "$HOME_DIR/data/boards.md"
  gate_probe
  expect_code 1 "$RC" "gate must refuse while an old name exists"
  assert_contains "$OUT" "cs-migrate-config.sh" "the refusal must name the migrator"
  assert_contains "$OUT" "boards.md" "the refusal must name the offending path"

  RC=0
  OUT=$(CS_HOME="$HOME_DIR" CS_LAYOUT_GATE_SKIP=1 \
    bash -c '. "'"$ROOT"'/bin/cs-root-lib.sh"; cs_resolve_root' 2>&1) || RC=$?
  expect_code 0 "$RC" "CS_LAYOUT_GATE_SKIP=1 must bypass the gate"

  run_migrate
  expect_code 0 "$RC" "migration clears the gate"
  gate_probe
  expect_code 0 "$RC" "gate must pass on a migrated home"
  pass "the layout gate fails closed on old names, honors the skip, passes when migrated"
}

test_migrates_and_preserves_symlinks
test_idempotent_and_absorbs_recreated_link
test_divergent_content_refuses
test_layout_gate
