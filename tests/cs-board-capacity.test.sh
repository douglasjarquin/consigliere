#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(cs_test_tmproot cs-board-capacity)
HOME_DIR="$TMP_ROOT/home"
PROJECT="$HOME_DIR/projects/proj"
STATE="$HOME_DIR/state"
GREEN_WT="$TMP_ROOT/green-wt"
ORPHAN="$TMP_ROOT/orphaned-task"
FAKEBIN=$(cs_fakebin "$TMP_ROOT")
FAKE_ROOT="$TMP_ROOT/root"
CAPACITY="$ROOT/bin/cs-board-capacity.sh"
BOARD_WATCH="$ROOT/bin/cs-board-watch.sh"
PR_CHECK="$ROOT/bin/cs-pr-check.sh"

mkdir -p "$HOME_DIR/data" "$HOME_DIR/config" "$STATE" "$ORPHAN" "$FAKE_ROOT/bin"
cs_git_init_commit "$PROJECT"
git -C "$PROJECT" worktree add --quiet -b cs/proj-301 "$GREEN_WT"
PROJECT_ABS=$(cd "$PROJECT" && pwd -P)
GREEN_HEAD=$(git -C "$GREEN_WT" rev-parse HEAD)
printf 'do not remove\n' > "$ORPHAN/keep.txt"
printf 'In Progress: issue 301\n' > "$HOME_DIR/config/board-card.txt"
printf 'proj o 7\n' > "$HOME_DIR/config/boards.md"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$FAKE_ROOT/bin/cs-guard.sh"
chmod +x "$FAKE_ROOT/bin/cs-guard.sh"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "pane get")
    case " ${CS_FAKE_LIVE_PANES:-} " in
      *" ${3:-} ") printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$3"; exit 0 ;;
      *) printf '{"error":{"code":"pane_not_found"}}\n'; exit 0 ;;
    esac
    ;;
  "status --json") printf '{"server":{"protocol":16}}\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -u
case " $* " in
  *" headRefOid "*) printf '%s\n' "${CS_FAKE_301_HEAD:?}" ;;
  *" state "*) printf '%s\n' "${CS_FAKE_POLL_STATE:-OPEN}" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/gh"

cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${CS_FAKE_AXI_LOG:?}"
[ "${1:-}" = api ] && [ "${2:-}" = POST ] && [ "${3:-}" = graphql ] || exit 1
case "$*" in
  *"pullRequest(number: 301)"*)
    if [ "${CS_FAKE_301_UNKNOWN:-0}" = 1 ]; then
      printf '%s\n' 'api_response:' '  body: "UNKNOWN"' '  truncated: false'
    else
      printf 'api_response:\n  body: "%s|%s|%s|%s|%s"\n  truncated: false\n' \
        "${CS_FAKE_301_STATE:-OPEN}" "${CS_FAKE_301_DRAFT:-false}" \
        "${CS_FAKE_301_HEAD:?}" "${CS_FAKE_301_CHECKS:-SUCCESS}" \
        "${CS_FAKE_301_REVIEW:-NONE}"
    fi
    ;;
  *"pullRequest(number: 303)"*)
    printf '%s\n' \
      'api_response:' \
      '  body: "MERGED|false|3333333333333333333333333333333333333333|SUCCESS|NONE"' \
      '  truncated: false'
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/gh-axi"

cat > "$FAKEBIN/board-gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "project view") printf '%s\n' '{"id":"PVT_board1","number":7,"title":"Board"}' ;;
  "project field-list")
    printf '%s\n' '{"fields":[{"id":"PVTSSF_status","name":"Status","options":[{"id":"opt_ready","name":"Ready"},{"id":"opt_wip","name":"In Progress"},{"id":"opt_done","name":"Done"},{"id":"opt_inbox","name":"Inbox"},{"id":"opt_backlog","name":"Backlog"}]}]}'
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/board-gh"

cat > "$HOME_DIR/config/backlog.md" <<'MD'
## In flight

- [ ] proj-301 - reviewed-green PR awaiting boss merge
- [ ] live-b - second live task
- [ ] live-c - third live task
- [ ] live-d - fourth live task
- [ ] live-e - fifth live task
- [ ] merged-orphan - merged task awaiting cleanup

## Queued

- [ ] ready-f - replacement work
MD

cs_write_meta "$STATE/proj-301.meta" \
  "pane=proj-301" "worktree=$GREEN_WT" "project=$PROJECT_ABS" "kind=ship" \
  "mode=no-mistakes" "issue=301"
printf 'done: PR https://github.com/o/r/pull/301 checks green\n' > "$STATE/proj-301.status"
for id in live-b live-c live-d live-e; do
  cs_write_meta "$STATE/$id.meta" \
    "pane=$id" "worktree=$TMP_ROOT/$id" "project=$PROJECT_ABS" "kind=ship"
done
cs_write_meta "$STATE/merged-orphan.meta" \
  "pane=" "worktree=$ORPHAN" "project=$PROJECT_ABS" "kind=ship" \
  "pr=https://github.com/o/r/pull/303" \
  "pr_head=3333333333333333333333333333333333333333"

run_watch() {
  env PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" CS_BOARD_GH="$FAKEBIN/board-gh" \
    "$BOARD_WATCH" "$@"
}

run_pr_check() {
  env PATH="$FAKEBIN:$PATH" CS_ROOT_OVERRIDE="$FAKE_ROOT" CS_HOME="$HOME_DIR" \
    CS_FAKE_301_HEAD="$GREEN_HEAD" \
    "$PR_CHECK" proj-301 https://github.com/o/r/pull/301
}

run_capacity() {
  env PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" \
    CS_FAKE_LIVE_PANES='proj-301 live-b live-c live-d live-e' \
    CS_FAKE_AXI_LOG="$TMP_ROOT/gh-axi.log" \
    CS_FAKE_301_HEAD="${CS_CASE_HEAD:-$GREEN_HEAD}" \
    CS_FAKE_301_STATE="${CS_CASE_STATE:-OPEN}" \
    CS_FAKE_301_DRAFT="${CS_CASE_DRAFT:-false}" \
    CS_FAKE_301_CHECKS="${CS_CASE_CHECKS:-SUCCESS}" \
    CS_FAKE_301_REVIEW="${CS_CASE_REVIEW:-NONE}" \
    CS_FAKE_301_UNKNOWN="${CS_CASE_UNKNOWN:-0}" \
    "$CAPACITY" proj "${1:-5}"
}

: > "$TMP_ROOT/gh-axi.log"
run_watch arm proj --lanes 5 --hold-green-prs >/dev/null \
  || fail "could not arm the ordinary five-lane sweep"
run_pr_check >/dev/null || fail "could not record the default PR-ready lifecycle"

reproduction=$(run_capacity) || fail "default capacity reproduction failed: $reproduction"
assert_contains "$reproduction" 'occupied=5' "ordinary unmerged PR still occupies by default"
assert_contains "$reproduction" 'released=0' "ordinary default releases no green PR"
assert_contains "$reproduction" 'free=0' "the five ordinary lanes remain full"
assert_contains "$reproduction" 'cleanup_pending=1' "merged cleanup remains separate from occupancy"
pass "reproduced the reviewed-green PR lane remaining occupied by default"

run_watch arm proj --lanes 5 --release-green-prs >/dev/null \
  || fail "could not arm green-PR capacity release"
run_pr_check >/dev/null || fail "could not record the release-ready PR lifecycle"
grep -qxF release-reviewed-green < <(tail -1 "$STATE/proj-301.pr-poll") \
  || fail "authenticated PR sidecar lacks the explicit release attestation"

released=$(run_capacity) || fail "released capacity query failed: $released"
assert_contains "$released" 'occupied=4' "matching reviewed-green PR stops occupying one slot"
assert_contains "$released" 'released=1' "exactly one scheduling slot is released"
assert_contains "$released" 'free=1' "five-lane capacity refills one lane"
assert_contains "$released" 'cleanup_pending=1' "green release does not consume merged cleanup"
pass "matching reviewed-green PR releases exactly one of five scheduling slots"

meta_before=$(shasum -a 256 "$STATE/proj-301.meta")
poll_before=$(shasum -a 256 "$STATE/proj-301.check.sh" "$STATE/proj-301.pr-poll" "$STATE/proj-301.pr-poll-registration")
backlog_before=$(shasum -a 256 "$HOME_DIR/config/backlog.md")
card_before=$(shasum -a 256 "$HOME_DIR/config/board-card.txt")
branch_before=$(git -C "$GREEN_WT" branch --show-current)
head_before=$(git -C "$GREEN_WT" rev-parse HEAD)

stale=$(CS_CASE_HEAD=2222222222222222222222222222222222222222 run_capacity)
assert_contains "$stale" 'released=0' "changed PR head stops releasing capacity"
assert_contains "$stale" 'occupied=5' "changed PR head restores occupancy"

red=$(CS_CASE_CHECKS=FAILURE run_capacity)
assert_contains "$red" 'released=0' "red checks do not release capacity"
assert_contains "$red" 'free=0' "red checks keep the five lanes full"

unknown=$(CS_CASE_UNKNOWN=1 run_capacity)
assert_contains "$unknown" 'released=0' "unknown PR checks do not release capacity"
assert_contains "$unknown" 'occupied=5' "unknown PR checks fail closed"

review_blocked=$(CS_CASE_REVIEW=CHANGES_REQUESTED run_capacity)
assert_contains "$review_blocked" 'released=0' "a new changes-requested review stops release"

cp "$STATE/proj-301.pr-poll" "$TMP_ROOT/proj-301.pr-poll.valid"
mv "$STATE/proj-301.pr-poll" "$STATE/proj-301.pr-poll.missing"
missing=$(run_capacity)
assert_contains "$missing" 'released=0' "missing release sidecar fails closed"
mv "$STATE/proj-301.pr-poll.missing" "$STATE/proj-301.pr-poll"
printf '%s\n' malformed > "$STATE/proj-301.pr-poll"
malformed=$(run_capacity)
assert_contains "$malformed" 'released=0' "malformed release sidecar fails closed"
cp "$TMP_ROOT/proj-301.pr-poll.valid" "$STATE/proj-301.pr-poll"
chmod 0600 "$STATE/proj-301.pr-poll"

cp "$HOME_DIR/data/sweeps.md" "$TMP_ROOT/sweeps.valid"
mv "$HOME_DIR/data/sweeps.md" "$HOME_DIR/data/sweeps.missing"
missing_policy=$(run_capacity)
assert_contains "$missing_policy" 'released=0' "missing sweep policy fails closed"
mv "$HOME_DIR/data/sweeps.missing" "$HOME_DIR/data/sweeps.md"
printf '%s\n%s\n' \
  '# Active board sweeps. Owned by bin/cs-board-watch.sh; do not hand-edit.' \
  'proj 5 1800 release-sometimes 2026-08-08T00:00:00Z' \
  > "$HOME_DIR/data/sweeps.md"
malformed_policy=$(run_capacity)
assert_contains "$malformed_policy" 'released=0' "malformed sweep policy fails closed"
cp "$TMP_ROOT/sweeps.valid" "$HOME_DIR/data/sweeps.md"
pass "stale, red, unknown, review-blocked, missing, and malformed release facts all hold safely"

leading_zero=$(run_capacity 08) || fail "leading-zero capacity query failed: $leading_zero"
assert_contains "$leading_zero" 'cap=8' "leading-zero cap is normalized as decimal"
assert_contains "$leading_zero" 'free=4' "released lane composes with decimal cap semantics"

[ "$meta_before" = "$(shasum -a 256 "$STATE/proj-301.meta")" ] \
  || fail "capacity accounting modified the task record"
[ "$poll_before" = "$(shasum -a 256 "$STATE/proj-301.check.sh" "$STATE/proj-301.pr-poll" "$STATE/proj-301.pr-poll-registration")" ] \
  || fail "capacity accounting modified the PR monitor or release attestation"
[ "$backlog_before" = "$(shasum -a 256 "$HOME_DIR/config/backlog.md")" ] \
  || fail "capacity accounting modified the backlog"
[ "$card_before" = "$(shasum -a 256 "$HOME_DIR/config/board-card.txt")" ] \
  || fail "capacity accounting modified the In Progress board card"
[ "$branch_before" = "$(git -C "$GREEN_WT" branch --show-current)" ] \
  || fail "capacity accounting changed the live branch"
[ "$head_before" = "$(git -C "$GREEN_WT" rev-parse HEAD)" ] \
  || fail "capacity accounting changed the live branch head"
[ -d "$GREEN_WT" ] || fail "capacity accounting removed the live worktree"
[ -d "$ORPHAN" ] || fail "capacity accounting removed the cleanup-pending directory"
assert_present "$ORPHAN/keep.txt" "capacity accounting modified the cleanup-pending directory"
assert_present "$STATE/merged-orphan.meta" "capacity accounting removed merged task metadata"
pass "release changes only capacity arithmetic and leaves branch, task, monitor, card, and cleanup intact"
