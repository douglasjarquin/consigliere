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
# "pane close" models the soldier being frozen: when CS_TEST_QUIESCE_CLEAN_FILE
# names a path, closing the pane removes it. A worktree left "dirty" only while
# the agent is live then reads clean iff the pane was closed before the proof.
case "$1 ${2:-}" in
  "workspace list") echo '{"result":{"workspaces":[]}}' ;;
  "pane list") echo '{"result":{"panes":[]}}' ;;
  "pane close")
    [ -n "${CS_TEST_QUIESCE_CLEAN_FILE:-}" ] && rm -f "$CS_TEST_QUIESCE_CLEAN_FILE"
    echo '{}' ;;
  # Presence is answered from the response BODY, and herdr puts the error body
  # on stderr with a non-zero exit (verified 0.7.5/protocol 17), so these arms
  # reproduce the real stream and status, not a convenient stdout stand-in.
  "pane get")
    case "${CS_TEST_PANE_PRESENCE:-dead}" in
      present)
        printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$3" ;;
      other-error)
        echo '{"error":{"code":"internal_error","message":"boom"}}' >&2; exit 1 ;;
      unparseable)
        echo 'Error: Os { code: 2, kind: NotFound, message: "No such file or directory" }' >&2; exit 1 ;;
      no-echo)
        echo '{"result":{"pane":{}}}' ;;
      *)
        printf '{"error":{"code":"pane_not_found","message":"pane %s not found"}}\n' "$3" >&2; exit 1 ;;
    esac ;;
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

# make_task <id> <kind> [mode]: fixture repo + linked worktree + meta.
# A ship meta carries the delivery posture cs-spawn.sh recorded for it; a scout
# meta carries none at all, because a report deliverable has no mode to honour
# and no approval posture to apply. The fixture mirrors that so the scout paths
# below are exercised against the metadata shape a real scout actually has.
make_task() {
  local id=$1 kind=$2 mode=${3:-no-mistakes} proj wt
  proj="$TMP/proj-$id"
  wt="$TMP/wt-$id"
  cs_git_init_commit "$proj"
  git -C "$proj" worktree add --quiet -b "cs/$id" "$wt"
  local meta=("workspace=w99" "pane=w99:p99" "worktree=$wt" "project=$proj" "kind=$kind")
  [ "$kind" = scout ] || meta+=("mode=$mode" "yolo=off")
  cs_write_meta "$TMP/state/$id.meta" "${meta[@]}"
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

# 4. clean no-new-work worktree proceeds, and the watcher's derived per-task /
#    per-pane markers are cleaned by exact name while a DIFFERENT task's / pane's
#    markers are left untouched (scoped deletion, never a broad glob).
make_task c1 ship  # id c1, pane w99:p99 -> pane key w99_p99
# c1's own derived markers (mirrors bin/cs-watch.sh key derivation)
c1_markers=(
  "$TMP/state/.seen-c1_status"
  "$TMP/state/.seen-c1_turn-ended"
  "$TMP/state/.hb-surfaced-c1"
  "$TMP/state/.hash-w99_p99"
  "$TMP/state/.count-w99_p99"
  "$TMP/state/.stale-w99_p99"
  "$TMP/state/.stale-since-w99_p99"
  "$TMP/state/.wedge-escalations-w99_p99"
  "$TMP/state/.herdr-escalated-w99_p99"
)
for m in "${c1_markers[@]}"; do : > "$m"; done
# markers belonging to a different task id / pane must survive teardown of c1
: > "$TMP/state/.seen-other_status"
: > "$TMP/state/.hb-surfaced-other"
: > "$TMP/state/.hash-w88_p88"
out=$("$BIN" c1 2>&1) || fail "clean teardown failed: $out"
assert_contains "$out" "teardown c1 complete" "clean teardown completes"
for m in "${c1_markers[@]}"; do assert_absent "$m" "watcher marker $(basename "$m") removed"; done
assert_present "$TMP/state/.seen-other_status" "other task's .seen marker untouched"
assert_present "$TMP/state/.hb-surfaced-other" "other task's .hb-surfaced marker untouched"
assert_present "$TMP/state/.hash-w88_p88" "other pane's .hash marker untouched"
pass "clean worktree teardown completes and cleans this task's watcher markers"

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

# 8. quiesce runs BEFORE the safety proof. A worktree that is "dirty" only while
# the soldier is live reads clean because the pane is closed first. Control (q0):
# the same dirty fixture refuses when closing the pane changes nothing, pinning
# that the file is genuinely dirty and only a pre-proof close makes it clean.
make_task q0 ship
echo live > "$TMP/wt-q0/scratch.txt"
out=$("$BIN" q0 2>&1) && fail "control: dirty worktree must refuse when pane close is inert"
assert_contains "$out" "uncommitted changes" "control fixture is genuinely dirty"
assert_present "$TMP/wt-q0/scratch.txt" "control dirty work preserved on refusal"

make_task q1 ship
echo live > "$TMP/wt-q1/scratch.txt"
out=$(CS_TEST_QUIESCE_CLEAN_FILE="$TMP/wt-q1/scratch.txt" "$BIN" q1 2>&1) \
  || fail "quiesce-before-proof teardown failed: $out"
assert_contains "$out" "teardown q1 complete" "frozen worktree reads clean, teardown proceeds"
assert_absent "$TMP/wt-q1" "worktree removed after quiesce-clean proof"
pass "pane quiesce runs before the safety proof"

# 9. Durable records are never erased for a pane that is not PROVEN gone.
# `pane close` reports success for a close that was refused and for a close that
# never reached the server, so only a structured pane_not_found may authorize
# removal; "present" and every flavour of "cannot tell" must refuse with the
# worktree, the branch, and every record intact so a rerun is a plain retry.
# Control (g0): the identical clean fixture completes when the pane is confirmed
# absent, pinning that the refusals below come from this gate and not from the
# landed-work proofs.
make_task g0 ship
: > "$TMP/state/g0.status"
out=$("$BIN" g0 2>&1) || fail "control: clean teardown must complete on a confirmed-gone pane: $out"
assert_contains "$out" "teardown g0 complete" "control fixture completes on a confirmed-gone pane"
assert_absent "$TMP/state/g0.meta" "control fixture cleaned its records"

for presence in present other-error unparseable no-echo; do
  id="g-$presence"
  make_task "$id" ship
  : > "$TMP/state/$id.status"
  out=$(CS_TEST_PANE_PRESENCE="$presence" "$BIN" "$id" 2>&1) \
    && fail "teardown must refuse when pane presence is '$presence'"
  assert_contains "$out" "cannot confirm pane" "refusal names the unconfirmed pane ($presence)"
  assert_present "$TMP/state/$id.meta" "meta retained ($presence)"
  assert_present "$TMP/state/$id.status" "status retained ($presence)"
  assert_present "$TMP/wt-$id" "worktree retained ($presence)"
  git -C "$TMP/proj-$id" show-ref --verify --quiet "refs/heads/cs/$id" \
    || fail "task branch must survive an unconfirmed-pane refusal ($presence)"
done
# A success body that does not echo the pane back is not an answer about THIS
# pane, so it must refuse rather than read as absence.
pass "records are retained unless the pane is proven gone"

# --force carries the boss's explicit discard authority and proceeds, matching
# how every other proof in this script treats --force - but it must SAY that it
# orphaned a live pane, because --force authorizes discarding unlanded work and
# stranding a running soldier is a different consequence than that.
make_task gf ship
out=$(CS_TEST_PANE_PRESENCE=present "$BIN" gf --force 2>&1) \
  || fail "--force must proceed past the confirmed-gone gate: $out"
assert_absent "$TMP/state/gf.meta" "--force clears records despite a live pane"
assert_contains "$out" "WARNING" "--force names the unproven pane instead of proceeding silently"
assert_contains "$out" "orphaned" "--force spells out the consequence of a surviving pane"
pass "--force proceeds past the gate but never silently"

# 10. Capo retirement removes exactly ONE route. A capo id may contain `.`, and
# the old `grep -vE "^- $id( |$)"` interpolated it into a pattern, so retiring
# `a.b` also matched - and DELETED - an unrelated `axb` route, silently
# unrouting a live capo. The registry here also ends without a trailing
# newline, the shape an id-less rewrite used to drop.
CAPO_ROOT="$TMP/capo-root"
cs_git_init_commit "$CAPO_ROOT"
mkdir -p "$TMP/capo-ab" "$TMP/capo-axb"
printf 'a.b\n' > "$TMP/capo-ab/.cs-capo-home"
printf 'axb\n' > "$TMP/capo-axb/.cs-capo-home"
{
  printf -- '- a.b - Dotted domain. (home: %s; scope: dotted work; projects: ; added 2026-01-01)\n' "$TMP/capo-ab"
  printf -- '- axb - Near miss domain. (home: %s; scope: near-miss work; projects: ; added 2026-01-01)' "$TMP/capo-axb"
} > "$TMP/data/capos.md"
cs_write_meta "$TMP/state/a.b.meta" \
  "workspace=w7" "pane=w7:p7" "kind=capo" "mode=capo" "home=$TMP/capo-ab"
out=$(CS_ROOT_OVERRIDE="$CAPO_ROOT" "$BIN" a.b 2>&1) || fail "capo retirement failed: $out"
assert_contains "$out" "teardown a.b complete" "capo retirement reports completion"
assert_absent "$TMP/capo-ab" "the retired capo home is removed"
assert_present "$TMP/capo-axb" "an unrelated capo home must survive a near-miss id"
assert_no_grep '- a.b ' "$TMP/data/capos.md" "the retired capo's route is removed"
assert_grep '- axb - Near miss domain.' "$TMP/data/capos.md" \
  "retiring a dotted id must not delete the near-miss route"
assert_absent "$TMP/state/a.b.meta" "capo records cleared after retirement"
pass "retiring a dotted capo id leaves the near-miss route intact"

pass "cs-teardown landed-work proofs"
