#!/usr/bin/env bash
# Behavior: cs-teardown.sh fail-closed landed-work proofs - refuses dirty and
# unlanded-committed worktrees, accepts squash-landed content, carves out
# scouts behind the report gate, and cleans volatile state on success.
# Hermetic: herdr and gh are faked; the workspace is reported absent so
# teardown takes the git-worktree removal path.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(cs_test_tmproot cs-teardown)
export CS_DATA_OVERRIDE="$TMP/data"
export CS_STATE_OVERRIDE="$TMP/state"
mkdir -p "$TMP/data" "$TMP/state"

FAKEBIN=$(cs_fakebin "$TMP")
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
# Hermetic herdr: empty workspace/pane lists, everything else succeeds.
case "$1 ${2:-}" in
  "workspace list") echo '{"result":{"workspaces":[]}}' ;;
  "pane list") echo '{"result":{"panes":[]}}' ;;
  *) echo '{}' ;;
esac
exit 0
SH
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cp "$FAKEBIN/gh" "$FAKEBIN/gh-axi"
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/gh" "$FAKEBIN/gh-axi"
export PATH="$FAKEBIN:$PATH"

cs_git_identity

BIN="$ROOT/bin/cs-teardown.sh"

# make_task <id> <kind> [mode]: fixture repo + linked worktree + meta
make_task() {
  local id=$1 kind=$2 mode=${3:-no-mistakes} proj wt
  proj="$TMP/proj-$id"
  wt="$TMP/wt-$id"
  cs_git_init_commit "$proj"
  git -C "$proj" worktree add --quiet -b "cs/$id" "$wt"
  cs_write_meta "$TMP/state/$id.meta" \
    "workspace=w99" \
    "pane=w99:p99" \
    "worktree=$wt" \
    "project=$proj" \
    "kind=$kind" \
    "mode=$mode" \
    "yolo=off"
}

# 1. dirty ship worktree refuses; work survives
make_task d1 ship
echo dirty > "$TMP/wt-d1/dirty.txt"
out=$("$BIN" d1 2>&1) && fail "dirty ship teardown must refuse"
assert_contains "$out" "uncommitted changes" "dirty refusal names the reason"
assert_present "$TMP/wt-d1/dirty.txt" "dirty work preserved"
assert_present "$TMP/state/d1.meta" "meta preserved on refusal"
pass "dirty ship worktree refuses"

# 2. committed-but-unlanded refuses
make_task u1 ship
echo change > "$TMP/wt-u1/feature.txt"
git -C "$TMP/wt-u1" add feature.txt
git -C "$TMP/wt-u1" commit -qm "unlanded feature"
out=$("$BIN" u1 2>&1) && fail "unlanded committed teardown must refuse"
assert_contains "$out" "not landed" "unlanded refusal names the reason"
assert_present "$TMP/wt-u1/feature.txt" "unlanded work preserved"
pass "committed-unlanded worktree refuses"

# 3. squash-landed content proceeds (content_in_default proof)
make_task s1 ship
echo landed > "$TMP/wt-s1/landed.txt"
git -C "$TMP/wt-s1" add landed.txt
git -C "$TMP/wt-s1" commit -qm "feature to land"
# Simulate a squash-merge into the default branch (different commit, same tree
# delta) in the primary checkout.
echo landed > "$TMP/proj-s1/landed.txt"
git -C "$TMP/proj-s1" add landed.txt
git -C "$TMP/proj-s1" commit -qm "feature (squashed)"
out=$("$BIN" s1 2>&1) || fail "squash-landed teardown failed: $out"
assert_contains "$out" "teardown s1 complete" "squash-landed teardown completes"
assert_absent "$TMP/wt-s1" "worktree removed"
assert_absent "$TMP/state/s1.meta" "meta cleaned"
git -C "$TMP/proj-s1" show-ref --verify --quiet refs/heads/cs/s1 \
  && fail "task branch should be deleted after teardown"
pass "squash-landed content teardown completes"

# 4. clean no-new-work worktree proceeds
make_task c1 ship
out=$("$BIN" c1 2>&1) || fail "clean teardown failed: $out"
assert_contains "$out" "teardown c1 complete" "clean teardown completes"
pass "clean worktree teardown completes"

# 5. scout without report refuses; with report proceeds even dirty
make_task sc1 scout
echo scratch > "$TMP/wt-sc1/scratch.txt"
out=$("$BIN" sc1 2>&1) && fail "scout without report must refuse"
assert_contains "$out" "no report" "scout refusal names the report"
mkdir -p "$TMP/data/sc1"
echo "# findings" > "$TMP/data/sc1/report.md"
touch "$TMP/state/sc1.status"
# The report alone is not enough: the unresolved-decision completion gate must
# also pass (cs-decision-hold.sh), exactly as at a real scout completion.
out=$("$BIN" sc1 2>&1) && fail "scout with report but no decision inventory must refuse"
assert_contains "$out" "unresolved-decision completion gate" "gate refusal names the inventory"
CS_HOME="$TMP" CS_STATE_OVERRIDE="$TMP/state" CS_DATA_OVERRIDE="$TMP/data" \
  "$ROOT/bin/cs-decision-hold.sh" complete sc1 --none >/dev/null || fail "decision inventory completion failed"
out=$("$BIN" sc1 2>&1) || fail "scout with report teardown failed: $out"
assert_contains "$out" "teardown sc1 complete" "scout teardown completes"
assert_absent "$TMP/wt-sc1" "scratch worktree removed"
assert_present "$TMP/data/sc1/report.md" "report survives teardown"
assert_absent "$TMP/state/sc1.status" "status cleaned"
pass "scout report gate"

# 6. --force discards a dirty ship worktree (explicit authority path)
make_task f1 ship
echo dirty > "$TMP/wt-f1/dirty.txt"
out=$("$BIN" f1 --force 2>&1) || fail "forced teardown failed: $out"
assert_absent "$TMP/wt-f1" "forced teardown removed worktree"
pass "--force discard path"

# 7. symlinked check artifact refuses cleanup
make_task a1 ship
ln -s /etc/hosts "$TMP/state/a1.check.sh"
out=$("$BIN" a1 2>&1) && fail "symlinked artifact must refuse"
assert_contains "$out" "symlink" "artifact refusal names the symlink"
pass "tampered artifact refuses cleanup"

pass "cs-teardown landed-work proofs"
