#!/usr/bin/env bash
# tests/cs-pr-watch.test.sh - the publish -> watcher-validate round trip for
# PR delivery: bin/cs-pr-check.sh publishes the byte-static merge poll, and a
# REAL bin/cs-watch.sh subprocess authenticates it with the real
# cs_pr_poll_artifacts_valid before dispatching bin/cs-pr-poll.sh with the
# validated sidecar identity. Also proves the watcher accepts a custom check
# registered through the real bin/cs-check-register.sh, and that a tampered
# published poll is rejected WITHOUT execution. Offline: fake herdr and
# cs-crew-state (tests/cs-watch-helpers.sh) plus a fake gh.
set -u

# shellcheck source=tests/cs-watch-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/cs-watch-helpers.sh"

WATCH="$ROOT/bin/cs-watch.sh"
PR_CHECK="$ROOT/bin/cs-pr-check.sh"
POLL="$ROOT/bin/cs-pr-poll.sh"
REGISTER="$ROOT/bin/cs-check-register.sh"

TMP_ROOT=$(cs_test_tmproot cs-pr-watch)

# Extend the shared offline case with a fake gh (merge-state answers driven by
# CS_TEST_GH_STATE, invocations logged) and a fake root whose cs-guard.sh is a
# no-op, so cs-pr-check.sh runs hermetically. Echoes the case dir.
make_pr_case() {
  local name=$1 dir fakebin
  dir=$(make_case "$name")
  fakebin="$dir/fakebin"
  mkdir -p "$dir/root/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/root/bin/cs-guard.sh"
  chmod +x "$dir/root/bin/cs-guard.sh"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CS_TEST_GH_LOG:-/dev/null}"
case " $* " in
  *" headRefOid "*) printf '%s\n' "${CS_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}" ;;
  *" state "*)
    [ "${CS_TEST_GH_FAIL:-0}" = 0 ] || exit 1
    printf '%s\n' "${CS_TEST_GH_STATE:-OPEN}"
    ;;
esac
SH
  chmod +x "$fakebin/gh"
  : > "$dir/gh.log"
  printf '%s\n' "$dir"
}

arm_pr_poll() {  # <case-dir> <id> <url>
  local dir=$1 id=$2 url=$3
  # No pane= in the meta: this suite exercises the check sweep, not the
  # stale-pane machinery.
  cs_write_meta "$dir/state/$id.meta" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  CS_ROOT_OVERRIDE="$dir/root" CS_STATE_OVERRIDE="$dir/state" \
    CS_TEST_GH_LOG="$dir/gh.log" PATH="$dir/fakebin:$PATH" \
    "$PR_CHECK" "$id" "$url" > "$dir/arm.out" 2> "$dir/arm.err" \
    || fail "cs-pr-check could not arm the merge poll: $(cat "$dir/arm.err")"
}

test_published_poll_round_trip_merged_wake() {
  local dir state out pid
  dir=$(make_pr_case poll-round-trip); state="$dir/state"; out="$dir/watch.out"
  arm_pr_poll "$dir" task https://github.com/o/r/pull/12
  cmp -s "$POLL" "$state/task.check.sh" || fail "armed check was not byte-for-byte bin/cs-pr-poll.sh"

  # Phase A: PR still open - the watcher validates and dispatches the poll,
  # which stays silent, so the watcher absorbs the sweep and keeps blocking.
  watch_bg "$state" "$dir/fakebin" "$out" \
    CS_CHECK_INTERVAL=1 CS_TEST_GH_STATE=OPEN CS_TEST_GH_LOG="$dir/gh.log"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited while the armed PR was still open: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "an open PR's silent poll printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "an open PR's silent poll enqueued a wake"
  grep -q 'pull/12' "$dir/gh.log" || fail "the watcher never dispatched the validated poll to gh"
  reap "$pid"

  # Phase B: the PR merges - the same published artifacts must pass the real
  # cs_pr_poll_artifacts_valid inside cs-watch.sh and surface one merged wake.
  cp "$state/task.meta" "$dir/meta.before-merge"
  : > "$out"
  rm -f "$state/.last-check"
  watch_bg "$state" "$dir/fakebin" "$out" \
    CS_CHECK_INTERVAL=1 CS_TEST_GH_STATE=MERGED CS_TEST_GH_LOG="$dir/gh.log"
  pid=$!
  wait_for_exit "$pid" 80 || fail "watcher did not surface the merged PR poll"
  grep -Fx "check: $state/task.check.sh: merged" "$out" >/dev/null \
    || fail "merged wake reason was not printed: $(cat "$out")"
  [ "$(count_wakes "$state" check "$state/task.check.sh")" -ge 1 ] \
    || fail "merged check wake was not queued"

  # The merge is terminal for this poll: its artifacts retire once the wake is
  # durably queued, so later cycles cannot re-notify the same merge. Task
  # metadata is teardown's to remove, never retirement's.
  [ ! -e "$state/task.check.sh" ] || fail "merged poll left its runnable check armed"
  [ ! -e "$state/task.pr-poll" ] || fail "merged poll left its data sidecar behind"
  [ ! -e "$state/task.pr-poll-registration" ] || fail "merged poll left its registration behind"
  assert_present "$state/task.meta" "retirement must not remove task metadata"
  grep -q '^pr=' "$state/task.meta" || fail "retirement dropped pr= from task metadata"
  cmp -s "$dir/meta.before-merge" "$state/task.meta" \
    || fail "retirement modified task metadata: $(diff "$dir/meta.before-merge" "$state/task.meta")"
  pass "a cs-pr-check publication passes the watcher's real validation, surfaces exactly the merged wake, and retires the poll"
}

# Retirement is identity-bound: if consigliere re-armed the poll for a
# different PR between the merged reading and the retirement, the replacement
# must stay armed rather than being silently disarmed by the older result.
test_retirement_leaves_a_rearmed_poll_alone() {
  local dir state
  dir=$(make_pr_case retire-identity); state="$dir/state"
  arm_pr_poll "$dir" task https://github.com/o/r/pull/12

  # shellcheck source=bin/cs-pr-lib.sh
  . "$ROOT/bin/cs-pr-lib.sh"

  cs_pr_poll_retire "$state" task "$POLL" \
    github https://github.com/o/r/pull/99 99 \
    && fail "retirement accepted an identity that does not match the armed poll"
  assert_present "$state/task.check.sh" "a mismatched identity must leave the check armed"
  assert_present "$state/task.pr-poll" "a mismatched identity must leave the data sidecar"
  assert_present "$state/task.pr-poll-registration" "a mismatched identity must leave the registration"

  cs_pr_poll_retire "$state" task "$POLL" \
    github https://github.com/o/r/pull/12 12 \
    || fail "retirement rejected the exact armed identity"
  [ ! -e "$state/task.check.sh" ] || fail "matching retirement left the check armed"
  pass "poll retirement only ever retires the exact identity that produced the merged result"
}

test_tampered_published_poll_rejected_without_execution() {
  local dir state out pid
  dir=$(make_pr_case poll-tampered); state="$dir/state"; out="$dir/watch.out"
  arm_pr_poll "$dir" task https://github.com/o/r/pull/13
  # Tamper the private sidecar AFTER publication: point it at another project.
  # The registration hash no longer matches, so the watcher must reject the
  # check without dispatching it (gh must never be consulted).
  printf '%s\n%s\n%s\n%s\n%s\n' \
    github https://github.com/attacker/elsewhere/pull/13 github.com attacker/elsewhere 13 \
    > "$state/task.pr-poll"
  chmod 0600 "$state/task.pr-poll"
  : > "$dir/gh.log"

  watch_bg "$state" "$dir/fakebin" "$out" \
    CS_CHECK_INTERVAL=1 CS_TEST_GH_STATE=MERGED CS_TEST_GH_LOG="$dir/gh.log"
  pid=$!
  wait_for_exit "$pid" 80 || fail "watcher did not surface the tampered-poll rejection"
  grep -F "check: rejected unauthenticated state checks: $state/task.check.sh" "$out" >/dev/null \
    || fail "tampered poll was not rejected: $(cat "$out")"
  [ ! -s "$dir/gh.log" ] || fail "a tampered poll WAS DISPATCHED (gh was called)"
  pass "a tampered published poll fails the watcher's real validation and is rejected without execution"
}

test_check_registered_via_registrar_accepted_by_watcher() {
  local dir state out pid check
  dir=$(make_pr_case registered-round-trip); state="$dir/state"; out="$dir/watch.out"
  check="$state/gate.check.sh"
  cat > "$check" <<'SH'
#!/usr/bin/env bash
echo "external gate cleared"
SH
  chmod 0700 "$check"
  CS_STATE_OVERRIDE="$state" "$REGISTER" gate > "$dir/register.out" \
    || fail "cs-check-register could not bind the custom check"
  grep -Fx 'registered: state/gate.check.sh' "$dir/register.out" >/dev/null \
    || fail "registrar confirmation line was not exact: $(cat "$dir/register.out")"

  watch_bg "$state" "$dir/fakebin" "$out" CS_CHECK_INTERVAL=1
  pid=$!
  wait_for_exit "$pid" 80 || fail "watcher did not surface the registered check's output"
  grep -Fx "check: $check: external gate cleared" "$out" >/dev/null \
    || fail "registered check output was not surfaced: $(cat "$out")"
  [ "$(count_wakes "$state" check "$check")" -ge 1 ] || fail "registered check wake was not queued"

  # Tamper after registration: the same watcher must now refuse it unexecuted.
  printf 'echo "tampered"\n' >> "$check"
  : > "$out"
  rm -f "$state/.last-check"
  watch_bg "$state" "$dir/fakebin" "$out" CS_CHECK_INTERVAL=1
  pid=$!
  wait_for_exit "$pid" 80 || fail "watcher did not surface the tampered registered-check rejection"
  grep -F "check: rejected unauthenticated state checks: $check" "$out" >/dev/null \
    || fail "tampered registered check was not rejected: $(cat "$out")"
  pass "a check bound by cs-check-register runs through the watcher, and its tampered bytes are refused"
}

test_published_poll_round_trip_merged_wake
test_retirement_leaves_a_rearmed_poll_alone
test_tampered_published_poll_rejected_without_execution
test_check_registered_via_registrar_accepted_by_watcher
