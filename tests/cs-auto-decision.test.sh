#!/usr/bin/env bash
# tests/cs-auto-decision.test.sh - bin/cs-auto-decision-lib.sh: a non-blocking,
# append-only ledger for bossless-mode auto-decisions, distinct from
# bin/cs-decision-hold.sh's blocking captain-hold machinery, plus
# cs_bossless_active (the one fail-closed "is bossless active right now"
# predicate) and cs_auto_decision_decide (the one record-then-close entry
# point that re-checks it).
set -u

# shellcheck source=tests/capo-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/capo-helpers.sh"
# shellcheck source=bin/cs-auto-decision-lib.sh
. "$ROOT/bin/cs-auto-decision-lib.sh"

TMP=$(cs_test_tmproot cs-auto-decision)
mkdir -p "$TMP"
FAKEBIN=$(cs_fakebin "$TMP")
cs_capo_fake_herdr "$FAKEBIN"
export PATH="$FAKEBIN:$PATH"
export CS_SEND_SETTLE=0
export FAKE_AGENT=codex FAKE_AGENT_STATUS=idle FAKE_PANE_EXISTS=1

# A fully bossless-ready fixture for <task_id>/<project>: state/, data/, an
# open decision under <key> in the task's own status file, a live pane, an
# armed away-mode flag, and an acknowledged bossless-ack record. Each of the
# four cs_bossless_active QA scenarios flips exactly one of these away from
# ready. Sets CS_HOME, STATE, DATA as globals for the caller (matching
# cs_resolve_root's own contract) and echoes nothing.
setup_bossless_fixture() {  # <case-name> <task_id> <project> <key>
  local case_name=$1 task_id=$2 project=$3 key=$4 home
  home="$TMP/$case_name-$RANDOM"
  CS_HOME=$home
  STATE="$home/state"
  DATA="$home/data"
  mkdir -p "$STATE" "$DATA" "$home/config"
  cs_write_meta "$STATE/$task_id.meta" "workspace=w1" "pane=w1:p1" "kind=ship" "yolo=on" "project=$project"
  printf 'needs-decision [key=%s]: pick an approach\n' "$key" > "$STATE/$task_id.status"
  date +%s > "$STATE/.afk"
  printf '%s acknowledged %s\n' "$(basename "$project")" "$(date +%s)" > "$home/config/bossless-ack.md"
  CS_BOSSLESS_ACK_OVERRIDE="$home/config/bossless-ack.md"
}

# 1. record then render round-trip: three categories recorded, rendered
#    output lists all three with the most severe first. Also proves no
#    blocking hold is ever created: real tasks-axi backs $CS_HOME here (never
#    a fake), and a captain hold created via bin/cs-decision-hold.sh's tasks_axi
#    wrapper always writes $CS_HOME/backlog.md - its absence after every
#    record() call in this scenario is a real side-effect proof, not a
#    source-text grep, that no hold of any kind was created.
CS_HOME="$TMP/record-render"
DATA="$CS_HOME/data"
mkdir -p "$DATA"
cs_auto_decision_record task1 routine "minor fix" "did X" "matches accepted intent" \
  || fail "recording a routine entry should succeed"
cs_auto_decision_record task1 destructive "deleted stale cache" "cleared it" "cache was corrupt" \
  || fail "recording a destructive entry should succeed"
cs_auto_decision_record task1 contract-expanding "added new endpoint" "added it" "needed for feature" \
  || fail "recording a contract-expanding entry should succeed"
log=$(cs_auto_decision_log_path task1)
[ -f "$log" ] || fail "the ledger file must be created"
[ "$(wc -l < "$log" | tr -d ' ')" = 3 ] || fail "the ledger must have exactly one line per record call"
rendered=$(cs_auto_decision_render task1)
assert_contains "$rendered" "deleted stale cache" "rendered output must list the destructive entry"
assert_contains "$rendered" "added new endpoint" "rendered output must list the contract-expanding entry"
assert_contains "$rendered" "minor fix" "rendered output must list the routine entry"
destructive_pos=$(printf '%s\n' "$rendered" | grep -n "deleted stale cache" | cut -d: -f1)
routine_pos=$(printf '%s\n' "$rendered" | grep -n "minor fix" | cut -d: -f1)
[ "$destructive_pos" -lt "$routine_pos" ] || fail "the destructive entry must render before the routine one"
[ ! -e "$CS_HOME/backlog.md" ] \
  || fail "cs_auto_decision_record must never create a tasks-axi backlog hold artifact"
pass "cs_auto_decision_record and cs_auto_decision_render round-trip, most-severe first, with no tasks-axi hold"

# 2. an invalid category is refused, and nothing is written.
DATA="$TMP/invalid-category/data"
mkdir -p "$DATA"
cs_auto_decision_record task2 not-a-real-category "x" "y" "z" 2>/dev/null \
  && fail "an invalid category must be refused"
[ ! -e "$(cs_auto_decision_log_path task2)" ] \
  || fail "a refused record call must not create the ledger file"
pass "an invalid category is refused before anything is written"

# 3. the ledger file survives a REAL bin/cs-teardown.sh run against the scout
#    task that recorded it (not a simulated one): scout teardown only ever
#    reads data/<id>/ (e.g. report.md) and never removes it, matching the
#    existing "task-scoped notes... survive teardown" placement already
#    proven for report.md. A dedicated fakebin supplies just enough herdr
#    contract (workspace absent, pane proven gone) for the real teardown
#    binary to run its scout path to completion; the real tasks-axi (never a
#    fake) backs bin/cs-decision-hold.sh's own unrelated completion gate.
CS_HOME="$TMP/survives-teardown"
STATE="$CS_HOME/state"
DATA="$CS_HOME/data"
TEARDOWN_PROJ="$TMP/survives-teardown-proj"
TEARDOWN_WT="$TMP/survives-teardown-wt"
mkdir -p "$STATE" "$DATA"
cs_git_init_commit "$TEARDOWN_PROJ"
git -C "$TEARDOWN_PROJ" worktree add --quiet -b cs/task3 "$TEARDOWN_WT"
cs_write_meta "$STATE/task3.meta" "workspace=w99" "pane=w99:p99" "worktree=$TEARDOWN_WT" \
  "project=$TEARDOWN_PROJ" "kind=scout"
cs_auto_decision_record task3 security-sensitive "rotated a credential" "rotated it" "expired" \
  || fail "recording before the real teardown should succeed"
log=$(cs_auto_decision_log_path task3)
[ -f "$log" ] || fail "the ledger file must exist before teardown"
mkdir -p "$DATA/task3"
echo "# findings" > "$DATA/task3/report.md"
touch "$STATE/task3.status"
TEARDOWN_FAKEBIN="$TMP/teardown-fakebin"
mkdir -p "$TEARDOWN_FAKEBIN"
cat > "$TEARDOWN_FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "workspace list") echo '{"result":{"workspaces":[]}}' ;;
  "pane list") echo '{"result":{"panes":[]}}' ;;
  "pane close") echo '{}' ;;
  "pane get")
    printf '{"error":{"code":"pane_not_found","message":"pane %s not found"}}\n' "${3:-}" >&2
    exit 1 ;;
  *) echo '{}' ;;
esac
exit 0
SH
chmod +x "$TEARDOWN_FAKEBIN/herdr"
PATH="$TEARDOWN_FAKEBIN:$PATH" CS_HOME="$CS_HOME" CS_STATE_OVERRIDE="$STATE" CS_DATA_OVERRIDE="$DATA" \
  "$ROOT/bin/cs-decision-hold.sh" complete task3 --none >/dev/null \
  || fail "decision inventory completion failed"
out=$(PATH="$TEARDOWN_FAKEBIN:$PATH" CS_HOME="$CS_HOME" CS_STATE_OVERRIDE="$STATE" CS_DATA_OVERRIDE="$DATA" \
  "$ROOT/bin/cs-teardown.sh" task3 2>&1) || fail "real teardown of task3 failed: $out"
assert_contains "$out" "teardown task3 complete" "the real teardown completes"
assert_present "$log" "the ledger file must still exist after a REAL, not simulated, teardown"
pass "the auto-decision ledger survives a real bin/cs-teardown.sh run"

# 4. cs_bossless_active refuses on each of the four inputs independently.
setup_bossless_fixture yolo-off taskA proj-yolo-off x
cs_write_meta "$STATE/taskA.meta" "workspace=w1" "pane=w1:p1" "kind=ship" "yolo=off" "project=proj-yolo-off"
cs_bossless_active taskA && fail "yolo=off must refuse bossless_active"

setup_bossless_fixture no-afk taskB proj-no-afk x
rm -f "$STATE/.afk"
cs_bossless_active taskB && fail "a missing state/.afk must refuse bossless_active"

setup_bossless_fixture unacked taskC proj-unacked x
rm -f "$CS_BOSSLESS_ACK_OVERRIDE"
cs_bossless_active taskC && fail "an unacknowledged project must refuse bossless_active"

setup_bossless_fixture killswitch taskD proj-killswitch x
printf 'proj-killswitch disabled\n' >> "$CS_BOSSLESS_ACK_OVERRIDE"
cs_bossless_active taskD && fail "a kill-switch-disabled project must refuse bossless_active"
pass "cs_bossless_active refuses on each of yolo=off, no state/.afk, unacknowledged, and kill-switch, independently"

# 5. auto-decide records then closes when truly active, in that order.
setup_bossless_fixture full-active taskE proj-active x
cs_auto_decision_decide taskE destructive "removed a broken symlink" "removed it" "target no longer existed" x \
  >/dev/null || fail "cs_auto_decision_decide should succeed when bossless is truly active"
log=$(cs_auto_decision_log_path taskE)
[ -f "$log" ] || fail "an active decision must write a ledger entry"
assert_contains "$(cat "$log")" "removed a broken symlink" "the ledger entry must carry the finding"
assert_contains "$(cat "$STATE/taskE.status")" "auto-decided (bossless): removed it - target no longer existed" \
  "the resolved line must carry the exact auto-decided (bossless) prefix"
assert_contains "$(cat "$STATE/taskE.status")" "resolved [key=x]: answered via cs-send: auto-decided (bossless):" \
  "cs-send.sh's own closing verb (Task 7) and the auto-decided (bossless) marker (Task 14) compose, neither replaces the other"
pass "cs_auto_decision_decide records then closes, with the exact auto-decided (bossless) prefix"

# 6. auto-decide refuses when the precondition is false, with no partial
#    side effects: no ledger entry, no resolved: line, finding stays open.
setup_bossless_fixture inactive taskF proj-inactive x
cs_write_meta "$STATE/taskF.meta" "workspace=w1" "pane=w1:p1" "kind=ship" "yolo=off" "project=proj-inactive"
cs_auto_decision_decide taskF routine "minor tweak" "did it" "harmless" x 2>/dev/null \
  && fail "cs_auto_decision_decide must refuse when bossless is inactive"
[ ! -e "$(cs_auto_decision_log_path taskF)" ] || fail "an inactive decision must not write a ledger entry"
assert_contains "$(cat "$STATE/taskF.status")" "needs-decision [key=x]: pick an approach" \
  "an inactive decision must leave the finding open exactly as an ordinary escalation would"
[ "$(grep -Fc 'resolved' "$STATE/taskF.status")" = 0 ] || fail "an inactive decision must not close the finding"
pass "cs_auto_decision_decide refuses when inactive, with no partial ledger or resolved-line side effects"

# 7. a ledger write failure blocks closure even when otherwise active.
setup_bossless_fixture ledger-fail taskG proj-ledger-fail x
chmod 0500 "$DATA"
cs_auto_decision_decide taskG routine "minor tweak" "did it" "harmless" x 2>/dev/null \
  && fail "cs_auto_decision_decide must fail when the ledger write itself fails"
chmod 0700 "$DATA"
assert_contains "$(cat "$STATE/taskG.status")" "needs-decision [key=x]: pick an approach" \
  "a ledger write failure must leave the finding open"
[ "$(grep -Fc 'resolved' "$STATE/taskG.status")" = 0 ] \
  || fail "a ledger write failure must never still close the finding"
pass "a ledger write failure blocks closure even when bossless is otherwise active"

pass "cs-auto-decision-lib.sh non-blocking ledger contract"
