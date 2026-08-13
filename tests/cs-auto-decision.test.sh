#!/usr/bin/env bash
# tests/cs-auto-decision.test.sh - bin/cs-auto-decision-lib.sh: a non-blocking,
# append-only ledger for bossless-mode auto-decisions, distinct from
# bin/cs-decision-hold.sh's blocking captain-hold machinery, plus
# cs_bossless_active (the one fail-closed "is bossless active right now"
# predicate) and cs_auto_decision_decide (the one record-then-close entry
# point that re-checks it), plus the bossless-mode acknowledgment gate and
# ack subcommand (bin/cs-afk-start.sh) that decides which projects reach it.
#
# The bossless-gate tests below set fixture env vars inside deliberate
# `( ... )` subshells for isolation between cases; the enclosing scope reads
# its own already-correct copy afterward, never the subshell's.
# shellcheck disable=SC2030,SC2031
set -u

# shellcheck source=tests/capo-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/capo-helpers.sh"
# shellcheck source=bin/cs-auto-decision-lib.sh
. "$ROOT/bin/cs-auto-decision-lib.sh"

AFK_START="$ROOT/bin/cs-afk-start.sh"
AFK_RETURN="$ROOT/bin/cs-afk-return.sh"

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
#    blocking hold is ever created: $CS_HOME carries the same .tasks.toml
#    markdown-backend wiring as the real repo root, so a captain hold created
#    via bin/cs-decision-hold.sh's tasks_axi wrapper (real tasks-axi, never a
#    fake) would land at $CS_HOME/config/backlog.md, exactly as
#    cs-decision-hold.sh's own error text names that path - its absence after
#    every record() call in this scenario is a real side-effect proof, not a
#    source-text grep, that no hold of any kind was created.
CS_HOME="$TMP/record-render"
DATA="$CS_HOME/data"
mkdir -p "$DATA" "$CS_HOME/config"
cp "$ROOT/.tasks.toml" "$CS_HOME/.tasks.toml"
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
[ ! -e "$CS_HOME/config/backlog.md" ] \
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

# 8. cs_bossless_ack_status/record (bin/cs-afk-start.sh) track acknowledgment
#    per project, and a later kill-switch line wins.
test_bossless_ack_status_record_and_kill_switch() {
  local dir ack
  dir="$TMP/bossless-ack-status-$RANDOM"; mkdir -p "$dir"
  ack="$dir/bossless-ack.md"
  (
    CS_BOSSLESS_ACK_OVERRIDE="$ack"
    export CS_BOSSLESS_ACK_OVERRIDE
    # shellcheck source=bin/cs-afk-start.sh
    . "$AFK_START"
    [ "$(cs_bossless_ack_status myproj)" = unacknowledged ] \
      || fail "a project with no record must read unacknowledged"
    cs_bossless_ack_record myproj || fail "recording an acknowledgment should succeed"
    [ "$(cs_bossless_ack_status myproj)" = acknowledged ] \
      || fail "myproj must read acknowledged after recording"
    [ "$(cs_bossless_ack_status otherproj)" = unacknowledged ] \
      || fail "recording myproj must not affect an unrelated project"
    printf 'myproj disabled\n' >> "$ack"
    [ "$(cs_bossless_ack_status myproj)" = disabled ] \
      || fail "a later disabled line (the kill switch) must win over an earlier acknowledged one"
  ) || fail "bossless ack status/record/kill-switch subshell failed"
  pass "cs_bossless_ack_status/record track acknowledgment per project, and a later kill-switch line wins"
}
test_bossless_ack_status_record_and_kill_switch

# 9. a corrupt acknowledgment file fails closed for every project, including
#    one whose own record DID parse.
test_bossless_ack_corrupt_file_fails_closed() {
  local dir ack
  dir="$TMP/bossless-ack-corrupt-$RANDOM"; mkdir -p "$dir"
  ack="$dir/bossless-ack.md"
  printf 'myproj acknowledged 1700000000\nGARBAGE LINE WITH NO STATUS\n' > "$ack"
  (
    CS_BOSSLESS_ACK_OVERRIDE="$ack"
    export CS_BOSSLESS_ACK_OVERRIDE
    # shellcheck source=bin/cs-afk-start.sh
    . "$AFK_START"
    [ "$(cs_bossless_ack_status myproj)" = unacknowledged ] \
      || fail "a corrupt file must fail closed even for a record that DID parse"
  ) || fail "bossless ack corrupt-file subshell failed"
  pass "a corrupt acknowledgment file fails closed for every project"
}
test_bossless_ack_corrupt_file_fails_closed

# 10. cs_afk_bossless_unacked_projects scans state/*.meta for yolo=on ship
#     tasks only, and drops an acknowledged project.
test_bossless_unacked_projects_scans_state_meta() {
  local dir state ack out
  dir="$TMP/bossless-unacked-scan-$RANDOM"; state="$dir/state"; mkdir -p "$state"
  ack="$dir/bossless-ack.md"
  mkdir -p "$dir/projects/proj-a" "$dir/projects/proj-b"
  cs_write_meta "$state/ship-a.meta" "kind=ship" "yolo=on" "project=$dir/projects/proj-a"
  cs_write_meta "$state/ship-b.meta" "kind=ship" "yolo=on" "project=$dir/projects/proj-b"
  cs_write_meta "$state/ship-c.meta" "kind=ship" "yolo=off" "project=$dir/projects/proj-a"
  cs_write_meta "$state/capo.meta" "kind=capo" "yolo=on" "project=$dir/projects/proj-a"
  out=$(
    CS_STATE_OVERRIDE="$state" CS_BOSSLESS_ACK_OVERRIDE="$ack"
    export CS_STATE_OVERRIDE CS_BOSSLESS_ACK_OVERRIDE
    # shellcheck source=bin/cs-afk-start.sh
    . "$AFK_START"
    cs_afk_bossless_unacked_projects
  )
  assert_contains "$out" "proj-a" "a yolo=on ship task's project must be reported as unacknowledged"
  assert_contains "$out" "proj-b" "a second yolo=on ship task's project must also be reported"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 2 ] \
    || fail "yolo=off and kind=capo tasks must not contribute extra projects: $out"
  out=$(
    CS_STATE_OVERRIDE="$state" CS_BOSSLESS_ACK_OVERRIDE="$ack"
    export CS_STATE_OVERRIDE CS_BOSSLESS_ACK_OVERRIDE
    # shellcheck source=bin/cs-afk-start.sh
    . "$AFK_START"
    cs_bossless_ack_record proj-a
    cs_afk_bossless_unacked_projects
  )
  assert_contains "$out" "proj-b" "proj-b must still be unacknowledged"
  case "$out" in
    *proj-a*) fail "proj-a must no longer appear once acknowledged: $out" ;;
  esac
  pass "cs_afk_bossless_unacked_projects scans state/*.meta for yolo=on ship tasks only, and drops an acknowledged project"
}
test_bossless_unacked_projects_scans_state_meta

# 11. cs-afk-start.sh's ack subcommand durably records the acknowledgment.
#     No fixture herdr needed: the ack subcommand never touches a pane.
test_afk_start_ack_subcommand_records_durably() {
  local dir ack out rc
  dir="$TMP/bossless-ack-cli-$RANDOM"; mkdir -p "$dir"
  ack="$dir/bossless-ack.md"
  out=$(CS_BOSSLESS_ACK_OVERRIDE="$ack" "$AFK_START" ack myproj 2>&1)
  rc=$?
  expect_code 0 "$rc" "cs-afk-start.sh ack <project>"
  assert_contains "$out" "bossless acknowledged for project 'myproj'" "the ack subcommand did not confirm by name"
  assert_present "$ack" "the ack subcommand did not create the acknowledgment file"
  grep -q '^myproj acknowledged [0-9]\+$' "$ack" \
    || fail "the acknowledgment file does not carry a well-formed record: $(cat "$ack")"
  out=$(CS_BOSSLESS_ACK_OVERRIDE="$ack" "$AFK_START" ack 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "ack with no project name must be refused"
  pass "cs-afk-start.sh ack <project> durably records the acknowledgment, and refuses with no project name"
}
test_afk_start_ack_subcommand_records_durably

# 12. the first bossless engagement for a project prompts by name; a later
#     one does not re-prompt after acknowledgment. cs-afk-start.sh no longer
#     touches herdr, a watcher, or the wedge alarm at all (nothing left to
#     launch), so this needs no fixture beyond state/*.meta and the ack file.
test_afk_start_first_engagement_prompts_second_does_not() {
  local dir state ack out rc
  dir="$TMP/bossless-first-engagement-$RANDOM"; state="$dir/state"; mkdir -p "$state"
  ack="$dir/bossless-ack.md"
  cs_write_meta "$state/ship-a.meta" "kind=ship" "yolo=on" "project=$dir/projects/proj-a"

  out=$(env CS_STATE_OVERRIDE="$state" CS_BOSSLESS_ACK_OVERRIDE="$ack" "$AFK_START" 2>&1)
  rc=$?
  expect_code 0 "$rc" "cs-afk-start on a fresh +yolo project with no acknowledgment"
  assert_contains "$out" "bossless mode would newly apply to project 'proj-a'" \
    "the first engagement must name the unacknowledged project explicitly"
  assert_present "$state/.afk" "away mode must still arm even with an unacknowledged bossless project"

  CS_BOSSLESS_ACK_OVERRIDE="$ack" "$AFK_START" ack proj-a >/dev/null \
    || fail "acknowledging proj-a should succeed"

  out=$(env CS_STATE_OVERRIDE="$state" CS_BOSSLESS_ACK_OVERRIDE="$ack" "$AFK_START" 2>&1)
  rc=$?
  expect_code 0 "$rc" "cs-afk-start refresh after acknowledgment"
  assert_contains "$out" "away mode refreshed" "the second run must be the ordinary refresh path"
  case "$out" in
    *"would newly apply to project"*) fail "an already-acknowledged project must not be re-prompted: $out" ;;
  esac
  pass "the first bossless engagement for a project prompts by name; a later one does not re-prompt after acknowledgment"
}
test_afk_start_first_engagement_prompts_second_does_not

# 13. two of the three "must stay narrow" states: (a) yolo=on with no afk
#     active, (b) yolo=off with afk active. The third (afk ends mid-task with
#     a decision already open) is its own test below, since it exercises the
#     real bin/cs-afk-return.sh return path rather than a static state.
test_bossless_narrow_states_refuse_auto_decide() {
  local dir state ack data
  dir="$TMP/bossless-narrow-states-$RANDOM"; state="$dir/state"; data="$dir/data"
  mkdir -p "$state" "$data"
  ack="$dir/bossless-ack.md"
  printf 'proj-narrow acknowledged 1700000000\n' > "$ack"

  # (a) yolo=on, no afk active.
  cs_write_meta "$state/narrowA.meta" "kind=ship" "yolo=on" "project=$dir/projects/proj-narrow"
  printf 'needs-decision [key=a]: pick an approach\n' > "$state/narrowA.status"
  rm -f "$state/.afk"
  (
    CS_STATE_OVERRIDE="$state" CS_DATA_OVERRIDE="$data" CS_BOSSLESS_ACK_OVERRIDE="$ack" CS_HOME="$dir"
    export CS_STATE_OVERRIDE CS_DATA_OVERRIDE CS_BOSSLESS_ACK_OVERRIDE CS_HOME
    # shellcheck source=bin/cs-auto-decision-lib.sh
    . "$ROOT/bin/cs-auto-decision-lib.sh"
    cs_auto_decision_decide narrowA routine "minor tweak" "did it" "harmless" a 2>/dev/null \
      && fail "(a) yolo=on with no afk active must refuse auto-decide"
    [ ! -e "$(cs_auto_decision_log_path narrowA)" ] || fail "(a) must not write a ledger entry"
  ) || fail "(a) subshell failed"
  grep -Fqx 'needs-decision [key=a]: pick an approach' "$state/narrowA.status" \
    || fail "(a) the decision must remain open and unresolved, exactly like an ordinary escalation"

  # (b) yolo=off, afk active.
  cs_write_meta "$state/narrowB.meta" "kind=ship" "yolo=off" "project=$dir/projects/proj-narrow"
  printf 'needs-decision [key=b]: pick an approach\n' > "$state/narrowB.status"
  date +%s > "$state/.afk"
  (
    CS_STATE_OVERRIDE="$state" CS_DATA_OVERRIDE="$data" CS_BOSSLESS_ACK_OVERRIDE="$ack" CS_HOME="$dir"
    export CS_STATE_OVERRIDE CS_DATA_OVERRIDE CS_BOSSLESS_ACK_OVERRIDE CS_HOME
    # shellcheck source=bin/cs-auto-decision-lib.sh
    . "$ROOT/bin/cs-auto-decision-lib.sh"
    cs_auto_decision_decide narrowB routine "minor tweak" "did it" "harmless" b 2>/dev/null \
      && fail "(b) yolo=off with afk active must refuse auto-decide"
    [ ! -e "$(cs_auto_decision_log_path narrowB)" ] || fail "(b) must not write a ledger entry"
  ) || fail "(b) subshell failed"
  grep -Fqx 'needs-decision [key=b]: pick an approach' "$state/narrowB.status" \
    || fail "(b) the decision must remain open and unresolved, exactly like an ordinary escalation"
  pass "bossless auto-decide stays off for yolo=on with no afk active, and for yolo=off with afk active"
}
test_bossless_narrow_states_refuse_auto_decide

# 14. the third narrow state, through the REAL return path rather than a
#     static check: neither bin/cs-afk-return.sh nor the retired
#     bin/cs-daemon.sh ever called the auto-decision machinery, so ending afk
#     with a needs-decision still open - boss-owned, deliberately not part of
#     the return gate that blocks on blocked: - leaves it untouched. This
#     proves the in-flight decision is never grandfathered into a decidable
#     state by the act of returning, and stays refused afterward too.
test_afk_return_does_not_retroactively_auto_decide_an_open_decision() {
  local dir state ack data rc out
  dir="$TMP/afk-return-no-retro-decide-$RANDOM"; state="$dir/state"; data="$dir/data"
  mkdir -p "$state" "$data"
  ack="$dir/bossless-ack.md"
  date '+%s' > "$state/.afk"
  cs_write_meta "$state/midtask.meta" "kind=ship" "yolo=on" "project=$dir/projects/proj-mid"
  printf 'needs-decision [key=mid]: pick an approach\n' > "$state/midtask.status"
  printf 'proj-mid acknowledged 1700000000\n' > "$ack"

  out=$(env CS_STATE_OVERRIDE="$state" "$AFK_RETURN" 2>&1)
  rc=$?
  expect_code 0 "$rc" "cs-afk-return with only an open needs-decision (boss-owned, ungated) must complete"
  assert_absent "$state/.afk" "return must clear the away-mode flag"
  grep -Fqx 'needs-decision [key=mid]: pick an approach' "$state/midtask.status" \
    || fail "the open decision must be untouched by return - no retroactive resolution"
  ! grep -q '^resolved' "$state/midtask.status" \
    || fail "ending afk must never itself close or auto-decide the standing open decision"

  (
    CS_STATE_OVERRIDE="$state" CS_DATA_OVERRIDE="$data" CS_BOSSLESS_ACK_OVERRIDE="$ack" CS_HOME="$dir"
    export CS_STATE_OVERRIDE CS_DATA_OVERRIDE CS_BOSSLESS_ACK_OVERRIDE CS_HOME
    # shellcheck source=bin/cs-auto-decision-lib.sh
    . "$ROOT/bin/cs-auto-decision-lib.sh"
    cs_auto_decision_decide midtask routine "picked an approach" "did X" "matches accepted intent" mid 2>/dev/null \
      && fail "a decision that outlived afk must not become auto-decidable after the fact"
    [ ! -e "$(cs_auto_decision_log_path midtask)" ] || fail "no ledger entry for the post-return attempt"
  ) || fail "post-return auto-decide subshell failed"
  grep -Fqx 'needs-decision [key=mid]: pick an approach' "$state/midtask.status" \
    || fail "the decision must still read open after the refused post-return attempt"
  pass "ending afk mid-task never retroactively auto-decides a standing open decision, and it stays refused to auto-decide afterward too"
}
test_afk_return_does_not_retroactively_auto_decide_an_open_decision

# 15. both delivery modes get a real bossless auto-decide (through the actual
#     cs_auto_decision_decide entry point, not a hand-written ledger line),
#     then a real cs-brief.sh-generated brief for that mode, then the EXACT
#     render-and-commit recipe extracted from that brief and run against a
#     scratch project repo - proving the ledger and the PR-attachment pointer
#     exist end to end, not just that the mechanisms exist in isolation.
test_bossless_ledger_and_pr_pointer_both_delivery_modes() {
  local dir state data ack pair mode id b recipe project
  dir="$TMP/bossless-both-modes-$RANDOM"; state="$dir/state"; data="$dir/data"
  mkdir -p "$state" "$data"
  ack="$dir/bossless-ack.md"
  date '+%s' > "$state/.afk"
  printf 'proj-both acknowledged 1700000000\n' > "$ack"

  for pair in "direct-PR:bothdp" "no-mistakes:bothnm"; do
    mode=${pair%%:*}
    id=${pair#*:}
    cs_write_meta "$state/$id.meta" "workspace=w1" "pane=w1:p1" "kind=ship" "yolo=on" "project=$dir/projects/proj-both"
    printf 'needs-decision [key=k-%s]: pick an approach\n' "$id" > "$state/$id.status"

    (
      CS_STATE_OVERRIDE="$state" CS_DATA_OVERRIDE="$data" CS_BOSSLESS_ACK_OVERRIDE="$ack" CS_HOME="$dir"
      export CS_STATE_OVERRIDE CS_DATA_OVERRIDE CS_BOSSLESS_ACK_OVERRIDE CS_HOME
      # shellcheck source=bin/cs-auto-decision-lib.sh
      . "$ROOT/bin/cs-auto-decision-lib.sh"
      cs_auto_decision_decide "$id" contract-expanding "extended an endpoint" "extended it" "needed for the feature" "k-$id" >/dev/null
    ) || fail "mode $mode: a real bossless auto-decide should succeed under a truly active fixture"
    grep -q "resolved \[key=k-$id\]" "$state/$id.status" \
      || fail "mode $mode: the decision must be resolved after a real bossless auto-decide"

    CS_DATA_OVERRIDE="$data" CS_STATE_OVERRIDE="$state" "$ROOT/bin/cs-brief.sh" "$id" alpha --mode "$mode" >/dev/null \
      || fail "mode $mode: brief scaffold failed"
    b="$data/$id/brief.md"
    assert_grep "cs_auto_decision_render $id" "$b" "mode $mode: brief renders this task's own ledger"
    assert_grep "docs/auto-decisions/$id.md" "$b" "mode $mode: brief names the committed evidence file"

    (
      set -eu
      project="$dir/proj-$id"
      mkdir -p "$project"
      cd "$project"
      git init -q
      git config user.email test@example.com
      git config user.name test
      touch placeholder && git add placeholder && git commit -q -m init
      recipe=$(awk '/^```$/{c++; next} c==1' "$b")
      eval "$recipe"
      [ -f "docs/auto-decisions/$id.md" ] || { echo "missing evidence file" >&2; exit 1; }
      grep -q "extended an endpoint" "docs/auto-decisions/$id.md" || { echo "entry missing" >&2; exit 1; }
    ) || fail "mode $mode: the real brief's own render-and-commit recipe did not produce the evidence file for a real auto-decide's ledger"
  done
  pass "the auto-decision ledger and the PR-attachment pointer exist end to end, for a real bossless auto-decide, in both delivery modes"
}
test_bossless_ledger_and_pr_pointer_both_delivery_modes

pass "cs-auto-decision-lib.sh non-blocking ledger contract"
