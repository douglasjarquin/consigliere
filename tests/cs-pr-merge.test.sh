#!/usr/bin/env bash
# tests/cs-pr-merge.test.sh - bin/cs-pr-merge.sh: the one path consigliere uses
# to merge a task's PR, which must always record pr= and any available
# pr_head= into the task's meta (through bin/cs-pr-check.sh) before merging so
# cs-teardown.sh's landed-check has a PR reference to verify against, even on
# repos with no PR CI where the usual "checks green" cs-pr-check.sh trigger
# never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) a valid GitLab merge request URL is refused LOUDLY by name
#   (h) explicit merge method is not overridden by the default --squash
#   (i) repo override args fail fast because the repo comes from the URL
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_MERGE="$ROOT/bin/cs-pr-merge.sh"
TMP_ROOT=$(cs_test_tmproot cs-pr-merge)

# The regression-has-teeth scenario below plants a fake caller INSIDE the
# repo tree (the grep it exercises is scoped to $ROOT, so a fixture outside
# it would prove nothing) - specifically under bin/, since the assertion's
# own allow-list deliberately excludes all of tests/ (ordinary test files
# legitimately reference the script by path with no autonomous call). This
# scratch path is guaranteed removed here even if an assertion fails
# mid-test, per tests/lib.sh's own documented override-and-chain pattern.
CS_PR_MERGE_REGRESSION_SCRATCH="$ROOT/bin/.cs-pr-merge-regression-scratch.sh"
cs_pr_merge_test_cleanup() {
  rm -f "$CS_PR_MERGE_REGRESSION_SCRATCH"
  cs_test_cleanup
}
trap cs_pr_merge_test_cleanup EXIT

# Build a fresh sandbox for one test case: a state dir with a task meta, a
# fake root with a guard stub (cs-pr-check.sh calls it), and a fakebin with a
# gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin" "$case_dir/root/bin"
  cat > "$case_dir/root/bin/cs-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/root/bin/cs-guard.sh"
  cs_write_meta "$case_dir/state/task-x1.meta" \
    "pane=cs-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for cs-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CS_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CS_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

run_pr_merge() {
  local case_dir=$1; shift
  CS_ROOT_OVERRIDE="$case_dir/root" \
  CS_STATE_OVERRIDE="$case_dir/state" \
  CS_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: cs-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "cs-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: cs-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "cs-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: cs-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "cs-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin" "$case_dir/root/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$case_dir/root/bin/cs-guard.sh"
  chmod +x "$case_dir/root/bin/cs-guard.sh"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: cs-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: cs-pr-check should not arm a poll for an unknown task"
  pass "cs-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://github.com/example/repo/pulls/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: cs-pr-merge should refuse a malformed PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "cs-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_gitlab_url_refused_loudly_before_merge() {
  local case_dir rc
  case_dir=$(make_case gitlab-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "gitlab-url: cs-pr-merge should refuse a GitLab merge request URL"
  assert_grep 'GitLab merge requests are not supported' "$case_dir/stderr" \
    "gitlab-url: refusal did not name GitLab as unsupported (silent misparse risk)"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "gitlab-url: GitLab merge request URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "gitlab-url: GitLab merge request URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "gitlab-url: gh-axi pr merge was invoked for a GitLab URL"
  pass "cs-pr-merge refuses a valid GitLab merge request URL loudly, by name, before any side effect"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "unsafe-url-segment: cs-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "unsafe-url-segment: refusal was not fixed and non-probing"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "cs-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: cs-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "cs-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: cs-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "cs-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: cs-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "cs-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: cs-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "cs-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

# Regression lock-in: bin/cs-pr-merge.sh must have zero autonomous callers
# anywhere in the repo, so a later change can never silently add one. The
# only allow-listed non-call reference is bin/cs-merge-local.sh's own
# error-message pointer, which names the script in a string, never invokes
# it.
assert_no_autonomous_pr_merge_callers() {
  grep -rn "cs-pr-merge\.sh" --include="*.sh" "$ROOT" 2>/dev/null \
    | grep -v "^$ROOT/bin/cs-pr-merge\.sh:" \
    | grep -v "^$ROOT/tests/" \
    | grep -v "^$ROOT/docs/" \
    | grep -v "^$ROOT/bin/cs-merge-local\.sh:.*merge PR tasks with bin/cs-pr-merge\.sh"
}

test_zero_autonomous_callers_of_pr_merge() {
  local hits
  hits=$(assert_no_autonomous_pr_merge_callers) || true
  [ -z "$hits" ] || fail "found an autonomous-looking reference to cs-pr-merge.sh outside the allow-list: $hits"
  pass "bin/cs-pr-merge.sh has zero autonomous callers repo-wide"
}

test_zero_autonomous_callers_regression_has_teeth() {
  # shellcheck disable=SC2016  # the literal text "$ROOT" is deliberate fixture content, not an expansion
  printf '#!/usr/bin/env bash\n"$ROOT/bin/cs-pr-merge.sh" "$@"\n' > "$CS_PR_MERGE_REGRESSION_SCRATCH"
  [ -n "$(assert_no_autonomous_pr_merge_callers)" ] \
    || fail "the assertion did not catch a fake new caller of cs-pr-merge.sh"
  rm -f "$CS_PR_MERGE_REGRESSION_SCRATCH"
  [ -z "$(assert_no_autonomous_pr_merge_callers)" ] \
    || fail "the assertion still fails after the fake caller was removed"
  pass "the zero-autonomous-callers assertion catches a real regression and clears once removed"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_gitlab_url_refused_loudly_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_zero_autonomous_callers_of_pr_merge
test_zero_autonomous_callers_regression_has_teeth
