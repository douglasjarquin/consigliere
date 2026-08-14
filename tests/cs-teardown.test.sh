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
export CS_CONFIG_OVERRIDE="$TMP/config"
export CS_HOST_OVERRIDE="$TMP/host"
mkdir -p "$TMP/data" "$TMP/state" "$TMP/config" "$TMP/host"

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
  # The event-transport unlink, recorded with whether the home it belongs to was
  # still on disk at that moment: the plugin id is derived from the home path, so
  # an unlink attempted after the removal could not name the right entry at all.
  "plugin unlink")
    if [ -d "${CS_TEST_PLUGIN_HOME:-/nonexistent}" ]; then
      printf '%s\thome-present\n' "$3" >> "${CS_TEST_PLUGIN_LOG:-/dev/null}"
    else
      printf '%s\thome-gone\n' "$3" >> "${CS_TEST_PLUGIN_LOG:-/dev/null}"
    fi
    if [ "${CS_TEST_PLUGIN_UNLINK_FAIL:-}" = 1 ]; then
      echo '{"error":{"code":"internal_error","message":"boom"}}' >&2
      exit 1
    fi
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
# Hermetic no-mistakes: the pre-teardown run conclusion (conclude_nm_run) queries
# `axi status` and, for a parked-and-attributed run, aborts it. This fake serves
# the env-driven TOON for `axi status` and models the daemon concluding the run:
# `axi abort` touches CS_FAKE_ABORT_MARK, after which `axi status` serves
# CS_FAKE_AXI_STATUS_AFTER instead. Default (both unset) is "no run" -> no-op, so
# every existing case above is unaffected and never touches the real binary.
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "axi status")
    if [ -n "${CS_FAKE_ABORT_MARK:-}" ] && [ -f "$CS_FAKE_ABORT_MARK" ]; then
      [ "${CS_FAKE_AXI_STATUS_AFTER_FAIL:-0}" = 1 ] && exit 17
      printf '%s\n' "${CS_FAKE_AXI_STATUS_AFTER:-}"
    else
      [ "${CS_FAKE_AXI_STATUS_FAIL:-0}" = 1 ] && exit 19
      printf '%s\n' "${CS_FAKE_AXI_STATUS:-}"
      if [ -n "${CS_FAKE_MUTATE_WORKTREE:-}" ]; then
        git -C "$CS_FAKE_MUTATE_WORKTREE" checkout -q "${CS_FAKE_MUTATE_BRANCH:?}"
      fi
    fi ;;
  "runs --limit")
    [ "${CS_FAKE_RUNS_FAIL:-0}" = 1 ] && exit 23
    printf '%s\n' "${CS_FAKE_RUNS_STATUS:-}" ;;
  "axi abort")
    [ -n "${CS_FAKE_ABORT_MARK:-}" ] && : > "$CS_FAKE_ABORT_MARK"
    echo '{}' ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/gh" "$FAKEBIN/gh-axi" "$FAKEBIN/no-mistakes"
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
  "$TMP/state/.decision-cursor-c1"
  "$TMP/state/.decision-cursor-c1.read.abc123"
  "$TMP/state/.decision-cursor-c1.tmp.abc123"
)
for m in "${c1_markers[@]}"; do : > "$m"; done
# markers belonging to a different task id / pane must survive teardown of c1
: > "$TMP/state/.seen-other_status"
: > "$TMP/state/.hb-surfaced-other"
: > "$TMP/state/.hash-w88_p88"
# a task whose id merely STARTS WITH c1 keeps its own cursor and staging temps
: > "$TMP/state/.decision-cursor-c1x"
: > "$TMP/state/.decision-cursor-c1x.read.abc123"
out=$("$BIN" c1 2>&1) || fail "clean teardown failed: $out"
assert_contains "$out" "teardown c1 complete" "clean teardown completes"
for m in "${c1_markers[@]}"; do assert_absent "$m" "watcher marker $(basename "$m") removed"; done
assert_present "$TMP/state/.seen-other_status" "other task's .seen marker untouched"
assert_present "$TMP/state/.hb-surfaced-other" "other task's .hb-surfaced marker untouched"
assert_present "$TMP/state/.hash-w88_p88" "other pane's .hash marker untouched"
assert_present "$TMP/state/.decision-cursor-c1x" "prefix-sibling task's cursor untouched"
assert_present "$TMP/state/.decision-cursor-c1x.read.abc123" \
  "prefix-sibling task's cursor staging temp untouched"
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
} > "$TMP/host/capos.md"
cs_write_meta "$TMP/state/a.b.meta" \
  "workspace=w7" "pane=w7:p7" "kind=capo" "mode=capo" "home=$TMP/capo-ab"
# The capo path clears this id's decision cursor and any staging temps a killed
# drain left behind, while an id that merely starts with a.b keeps its own.
: > "$TMP/state/.decision-cursor-a.b"
: > "$TMP/state/.decision-cursor-a.b.read.abc123"
: > "$TMP/state/.decision-cursor-a.b.tmp.abc123"
: > "$TMP/state/.decision-cursor-a.bx"
: > "$TMP/state/.decision-cursor-a.bx.read.abc123"
out=$(CS_ROOT_OVERRIDE="$CAPO_ROOT" "$BIN" a.b 2>&1) || fail "capo retirement failed: $out"
assert_contains "$out" "teardown a.b complete" "capo retirement reports completion"
assert_absent "$TMP/capo-ab" "the retired capo home is removed"
assert_present "$TMP/capo-axb" "an unrelated capo home must survive a near-miss id"
assert_no_grep '- a.b ' "$TMP/host/capos.md" "the retired capo's route is removed"
assert_grep '- axb - Near miss domain.' "$TMP/host/capos.md" \
  "retiring a dotted id must not delete the near-miss route"
assert_absent "$TMP/state/a.b.meta" "capo records cleared after retirement"
assert_absent "$TMP/state/.decision-cursor-a.b" "capo retirement clears its decision cursor"
assert_absent "$TMP/state/.decision-cursor-a.b.read.abc123" \
  "capo retirement reclaims an orphaned cursor read temp"
assert_absent "$TMP/state/.decision-cursor-a.b.tmp.abc123" \
  "capo retirement reclaims an orphaned cursor staging temp"
assert_present "$TMP/state/.decision-cursor-a.bx" \
  "a prefix-sibling id's cursor must survive a capo retirement"
assert_present "$TMP/state/.decision-cursor-a.bx.read.abc123" \
  "a prefix-sibling id's cursor staging temp must survive a capo retirement"
pass "retiring a dotted capo id leaves the near-miss route intact"

# 11. Capo retirement unlinks that home's herdr event plugin, while the home is
# still on disk. herdr's plugin registry is GLOBAL to the user and the plugin id
# carries a digest of the home path, so an entry left behind after the directory
# is gone can never be named again: herdr would keep dispatching every pane's
# status edge on the machine to a deleted hook. The unlink is also fail-open -
# the retirement's own safety proofs have already passed by then, so neither a
# herdr that rejects the unlink nor a plugin script that cannot run at all may
# turn a proven retirement into a failure.
PLUGIN_LOG="$TMP/plugin-unlinks.log"
: > "$PLUGIN_LOG"
export CS_TEST_PLUGIN_LOG="$PLUGIN_LOG"

# make_capo <id> <home>: a retirable capo fixture - marked home, route, meta.
make_capo() {
  local id=$1 home=$2
  mkdir -p "$home"
  printf '%s\n' "$id" > "$home/.cs-capo-home"
  printf -- '- %s - Event domain. (home: %s; scope: event work; projects: ; added 2026-01-01)\n' \
    "$id" "$home" >> "$TMP/host/capos.md"
  cs_write_meta "$TMP/state/$id.meta" \
    "workspace=w8" "pane=w8:p8" "kind=capo" "mode=capo" "home=$home"
}

# The id the transport itself derives for a home, asked of the script that owns
# it rather than recomputed here, so the assertion pins the real registration.
capo_plugin_id() {  # <home>
  CS_HOME="$1" CS_STATE_OVERRIDE="$1/state" CS_HOST_OVERRIDE="$1/host" \
    CS_DATA_OVERRIDE="$1/data" CS_CONFIG_OVERRIDE="$1/config" \
    "$ROOT/bin/cs-herdr-event-plugin.sh" id
}

EVT_HOME="$TMP/capo-evt"
make_capo evt "$EVT_HOME"
EVT_PLUGIN_ID=$(capo_plugin_id "$EVT_HOME")
[ -n "$EVT_PLUGIN_ID" ] || fail "the event plugin reported no id for the capo home"
out=$(env -u CS_EVENT_PLUGIN_DISABLE CS_ROOT_OVERRIDE="$CAPO_ROOT" \
  CS_TEST_PLUGIN_HOME="$EVT_HOME" "$BIN" evt 2>&1) \
  || fail "capo retirement with the event transport installed failed: $out"
assert_contains "$out" "teardown evt complete" "capo retirement still reports completion"
assert_absent "$EVT_HOME" "the retired capo home is removed"
assert_grep "$EVT_PLUGIN_ID"$'\t'"home-present" "$PLUGIN_LOG" \
  "capo retirement must unlink THIS home's plugin while the home still exists"
pass "capo retirement unlinks its herdr event plugin before removing the home"

# A herdr that refuses the unlink, and a plugin script that cannot run at all (an
# unmigrated home trips the layout gate and exits non-zero): both must leave the
# retirement itself untouched.
FAIL_HOME="$TMP/capo-evtfail"
make_capo evtfail "$FAIL_HOME"
FAIL_PLUGIN_ID=$(capo_plugin_id "$FAIL_HOME")
out=$(env -u CS_EVENT_PLUGIN_DISABLE CS_ROOT_OVERRIDE="$CAPO_ROOT" \
  CS_TEST_PLUGIN_HOME="$FAIL_HOME" CS_TEST_PLUGIN_UNLINK_FAIL=1 "$BIN" evtfail 2>&1) \
  || fail "a herdr that rejects the unlink must not fail a proven retirement: $out"
assert_contains "$out" "teardown evtfail complete" "retirement completes despite the unlink error"
assert_absent "$FAIL_HOME" "the retired capo home is removed despite the unlink error"
assert_grep "$FAIL_PLUGIN_ID"$'\t'"home-present" "$PLUGIN_LOG" \
  "the rejected unlink was still attempted while the home existed"

LEGACY_HOME="$TMP/capo-legacy"
make_capo legacy "$LEGACY_HOME"
mkdir -p "$LEGACY_HOME/config"
: > "$LEGACY_HOME/config/permission-mode"
out=$(env -u CS_EVENT_PLUGIN_DISABLE CS_ROOT_OVERRIDE="$CAPO_ROOT" \
  CS_TEST_PLUGIN_HOME="$LEGACY_HOME" "$BIN" legacy 2>&1) \
  || fail "a plugin script that cannot run must not fail a proven retirement: $out"
assert_contains "$out" "teardown legacy complete" "retirement completes when the plugin script dies"
assert_absent "$LEGACY_HOME" "the retired capo home is removed when the plugin script dies"
pass "a failing plugin unlink never blocks a capo retirement"

# CS_EVENT_PLUGIN_DISABLE (set for every suite by tests/lib.sh) must reach the
# uninstall too: herdr's registry is the developer's own, and a suite that
# retired a throwaway capo must never send it a plugin command.
DIS_HOME="$TMP/capo-dis"
make_capo dis "$DIS_HOME"
DIS_PLUGIN_ID=$(capo_plugin_id "$DIS_HOME")
out=$(CS_ROOT_OVERRIDE="$CAPO_ROOT" CS_TEST_PLUGIN_HOME="$DIS_HOME" "$BIN" dis 2>&1) \
  || fail "capo retirement with the plugin seam disabled failed: $out"
assert_contains "$out" "teardown dis complete" "retirement completes with the plugin seam disabled"
assert_no_grep "$DIS_PLUGIN_ID" "$PLUGIN_LOG" \
  "CS_EVENT_PLUGIN_DISABLE must keep the retirement away from the user-global registry"
pass "CS_EVENT_PLUGIN_DISABLE keeps capo retirement out of the herdr registry"

make_task m1 ship local-only
out=$(CS_FAKE_AXI_STATUS_FAIL=1 "$BIN" m1 2>&1) || fail "non-no-mistakes teardown must skip run conclusion: $out"
assert_contains "$out" "teardown m1 complete" "non-no-mistakes mode skips the run conclusion"
pass "non-no-mistakes mode skips run conclusion"

make_task f1 ship
out=$(CS_FAKE_AXI_STATUS_FAIL=1 "$BIN" f1 2>&1) \
  && fail "an unreadable no-mistakes status must refuse teardown"
assert_contains "$out" "could not verify that no orphaned" "unreadable status refusal names the orphan check"
assert_present "$TMP/wt-f1" "worktree retained after unreadable status refusal"
assert_present "$TMP/state/f1.meta" "records retained after unreadable status refusal"
pass "unreadable no-mistakes status fails closed"

# --- pre-teardown run conclusion + leaked-process reap ----------------------
# A run is attributed to a task only by its exact branch AND current head
# (bin/cs-nm-run-lib.sh, the shared owner cs-crew-state.sh also uses). These
# builders emit the TOON `axi status` returns.
parked_run() {  # <branch> <head>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 7h39m
  head: "$2"
gate: review
EOF
}
cancelled_run() {  # <branch> <head>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "$2"
outcome: cancelled
EOF
}

# 11. A parked run attributed to this exact task is aborted, the abort is
# confirmed, and only then does teardown proceed. The worktree sits at its
# landed base (content_in_default), so the landed-work proof passes and the only
# thing standing between the task and cleanup is the parked run.
make_task p1 ship
p1_head=$(git -C "$TMP/wt-p1" rev-parse HEAD)
p1_mark="$TMP/state/p1.aborted"
out=$(CS_FAKE_ABORT_MARK="$p1_mark" \
      CS_FAKE_AXI_STATUS="$(parked_run cs/p1 "$p1_head")" \
      CS_FAKE_AXI_STATUS_AFTER="$(cancelled_run cs/p1 "$p1_head")" \
      "$BIN" p1 2>&1) || fail "parked-run teardown failed: $out"
assert_present "$p1_mark" "the parked run was aborted"
assert_contains "$out" "teardown p1 complete" "teardown proceeds after the run is concluded"
assert_absent "$TMP/wt-p1" "worktree removed after the run was concluded"
pass "a parked run attributed to this task is aborted and confirmed before cleanup"

# 12. A parked run whose abort does NOT stick (still parked on re-check) is a
# fail-closed refusal naming what survived - never a silent proceed.
make_task p2 ship
p2_head=$(git -C "$TMP/wt-p2" rev-parse HEAD)
p2_mark="$TMP/state/p2.aborted"
out=$(CS_FAKE_ABORT_MARK="$p2_mark" \
      CS_FAKE_AXI_STATUS="$(parked_run cs/p2 "$p2_head")" \
      CS_FAKE_AXI_STATUS_AFTER="$(parked_run cs/p2 "$p2_head")" \
      "$BIN" p2 2>&1) && fail "a run that stays parked after abort must refuse teardown"
assert_contains "$out" "still parked at a gate" "the refusal names the run that would not conclude"
assert_present "$TMP/wt-p2" "worktree retained when the run would not conclude"
assert_present "$TMP/state/p2.meta" "records retained when the run would not conclude"
pass "a parked run that will not conclude fails the teardown closed"

make_task p2t ship
p2t_head=$(git -C "$TMP/wt-p2t" rev-parse HEAD)
p2t_mark="$TMP/state/p2t.aborted"
git -C "$TMP/wt-p2t" branch cs/p2t-other
out=$(CS_FAKE_ABORT_MARK="$p2t_mark" \
      CS_FAKE_AXI_STATUS="$(parked_run cs/p2t "$p2t_head")" \
      CS_FAKE_MUTATE_WORKTREE="$TMP/wt-p2t" \
      CS_FAKE_MUTATE_BRANCH=cs/p2t-other \
      "$BIN" p2t 2>&1) && fail "a changed task identity must refuse teardown"
assert_contains "$out" "identity changed under teardown" "identity mismatch refusal names the changed task identity"
assert_absent "$p2t_mark" "identity mismatch does not issue an abort"
assert_present "$TMP/wt-p2t" "worktree retained after identity mismatch"
assert_present "$TMP/state/p2t.meta" "records retained after identity mismatch"
pass "identity mismatch refuses abort without touching the run"

make_task p2u ship
p2u_head=$(git -C "$TMP/wt-p2u" rev-parse HEAD)
p2u_mark="$TMP/state/p2u.aborted"
out=$(CS_FAKE_ABORT_MARK="$p2u_mark" \
      CS_FAKE_AXI_STATUS="$(parked_run cs/p2u "$p2u_head")" \
      CS_FAKE_AXI_STATUS_AFTER_FAIL=1 \
      "$BIN" p2u 2>&1) && fail "an unreadable post-abort status must refuse teardown"
assert_contains "$out" "could not confirm" "unreadable post-abort status names the missing confirmation"
assert_present "$TMP/wt-p2u" "worktree retained after unreadable post-abort status"
assert_present "$TMP/state/p2u.meta" "records retained after unreadable post-abort status"
pass "unreadable post-abort status fails closed"

# 13. A parked run on ANOTHER branch is never touched; teardown proceeds and no
# abort is issued.
make_task p3 ship
p3_mark="$TMP/state/p3.aborted"
out=$(CS_FAKE_ABORT_MARK="$p3_mark" \
      CS_FAKE_AXI_STATUS="$(parked_run cs/some-other-branch "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")" \
      "$BIN" p3 2>&1) || fail "other-branch run must not block teardown: $out"
assert_absent "$p3_mark" "a run on another branch is never aborted"
assert_contains "$out" "teardown p3 complete" "teardown proceeds past another branch's run"
pass "a parked run on another branch is left untouched"

# 14. A run on THIS branch but at a diverged/rewritten head (the recorded head is
# no longer in this worktree) is not attributed, so it is never touched.
make_task p4 ship
p4_mark="$TMP/state/p4.aborted"
out=$(CS_FAKE_ABORT_MARK="$p4_mark" \
      CS_FAKE_AXI_STATUS="$(parked_run cs/p4 "cafebabecafebabecafebabecafebabecafebabe")" \
      "$BIN" p4 2>&1) || fail "diverged-head run must not block teardown: $out"
assert_absent "$p4_mark" "a run at a diverged head on this branch is never aborted"
assert_contains "$out" "teardown p4 complete" "teardown proceeds past a diverged-head run"
pass "a run on this branch at a diverged head is left untouched"

# 15. A retried teardown after a partial first attempt converges. First attempt
# refuses because the run stays parked; the second attempt runs against a run
# that is now concluded (abort stuck) and completes.
make_task p5 ship
p5_head=$(git -C "$TMP/wt-p5" rev-parse HEAD)
p5_mark="$TMP/state/p5.aborted"
out=$(CS_FAKE_ABORT_MARK="$p5_mark" \
      CS_FAKE_AXI_STATUS="$(parked_run cs/p5 "$p5_head")" \
      CS_FAKE_AXI_STATUS_AFTER="$(parked_run cs/p5 "$p5_head")" \
      "$BIN" p5 2>&1) && fail "first attempt must refuse while the run stays parked"
assert_present "$TMP/wt-p5" "worktree retained after the refusing first attempt"
# Second attempt: the run now reads concluded regardless of the abort marker.
out=$(CS_FAKE_AXI_STATUS="$(cancelled_run cs/p5 "$p5_head")" "$BIN" p5 2>&1) \
  || fail "retried teardown must converge: $out"
assert_contains "$out" "teardown p5 complete" "retried teardown converges once the run is concluded"
assert_absent "$TMP/wt-p5" "worktree removed on the converging retry"
pass "a retried teardown after a partial first attempt converges"

# 16. Leaked task processes (cwd under the worktree) are TERM/KILLed; a process
# rooted elsewhere is never signaled. Uses real processes and lsof, not herdr.
if command -v lsof >/dev/null 2>&1; then
  make_task r1 ship
  mkdir -p "$TMP/wt-r1/sub"
  ELSEWHERE=$(mktemp -d "$TMP/elsewhere.XXXXXX")
  ( cd "$TMP/wt-r1/sub" && exec sleep 60 ) & leaked_pid=$!
  ( cd "$ELSEWHERE" && exec sleep 60 ) & control_pid=$!
  sleep 0.3
  out=$(cd "$TMP/wt-r1" && "$BIN" r1 2>&1) || fail "reap-path teardown failed: $out"
  assert_contains "$out" "teardown r1 complete" "teardown completes after reaping"
  wait "$leaked_pid" 2>/dev/null
  kill -0 "$leaked_pid" 2>/dev/null && fail "a process rooted under the worktree must be reaped"
  kill -0 "$control_pid" 2>/dev/null || fail "a process rooted elsewhere must not be signaled"
  kill "$control_pid" 2>/dev/null
  wait "$control_pid" 2>/dev/null
  pass "leaked worktree processes are reaped and unrelated processes are spared"
else
  pass "leaked-process reap (skipped: lsof unavailable)"
fi

pass "cs-teardown landed-work proofs"
