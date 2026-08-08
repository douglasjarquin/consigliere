#!/usr/bin/env bash
# tests/cs-pr-check.test.sh - security and behavior tests for canonical PR
# parsing (bin/cs-pr-lib.sh), the arming entrypoint (bin/cs-pr-check.sh), and
# the byte-static merge poll (bin/cs-pr-poll.sh). Offline: gh is a fakebin
# stub, the guard is a fake-root stub. Consigliere is GitHub-only: a valid
# GitLab merge request URL must be refused LOUDLY (recognized exactly, never
# silently misparsed) and a gitlab-tagged sidecar must keep the poll silent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/cs-pr-lib.sh
. "$ROOT/bin/cs-pr-lib.sh"

PR_CHECK="$ROOT/bin/cs-pr-check.sh"
POLL="$ROOT/bin/cs-pr-poll.sh"
TMP_ROOT=$(cs_test_tmproot cs-pr-check)
BASE_PATH=${CS_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
REAL_CP=$(command -v cp)

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

state_snapshot() {
  local state=$1 file
  (
    cd "$state" || exit 1
    find . \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r file; do
      if [ -L "$file" ]; then
        printf 'link %s %s\n' "$file" "$(readlink "$file")"
      else
        printf 'file %s %s ' "$file" "$(file_mode "$file")"
        shasum -a 256 "$file" | awk '{print $1}'
      fi
    done
  )
}

make_case() {
  local name=$1 dir fakebin fake_root
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  fake_root="$dir/root"
  mkdir -p "$dir/home/state" "$dir/wt" "$fakebin" "$fake_root/bin"
  cat > "$fake_root/bin/cs-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "$CS_TEST_GUARD_LOG"
SH
  chmod +x "$fake_root/bin/cs-guard.sh"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CS_TEST_GH_LOG"
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
  : > "$dir/guard.log"
  printf '%s\n' "$dir"
}

write_task_meta() {
  local dir=$1 id=${2:-task-a}
  cs_write_meta "$dir/home/state/$id.meta" \
    "pane=cs-$id" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
}

run_check_entry() {
  local dir=$1
  shift
  CS_ROOT_OVERRIDE="$dir/root" CS_HOME="$dir/home" \
    CS_TEST_GUARD_LOG="$dir/guard.log" CS_TEST_GH_LOG="$dir/gh.log" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" "$@"
}

# shellcheck disable=SC2016 # Literal rejected URL bytes are parser test data.
INVALID_URLS=(
  'https://gitlab.com/single/-/merge_requests/1'
  'https://gitlab.com/g/p/-/merge_requests/0'
  'https://gitlab.com/g/p/-/merge_requests/01'
  'https://GitLab.com/g/p/-/merge_requests/1'
  'https://gitlab.com:443/g/p/-/merge_requests/1'
  'https://user@gitlab.com/g/p/-/merge_requests/1'
  'https://gitlab.com/g/p/-/merge_requests/1/'
  'https://gitlab.com/-/p/-/merge_requests/1'
  'https://gitlab.com/g/p.git/-/merge_requests/1'
  'https://gitlab.com/g/p/-/merge_requests/1?x=1'
  'https://gitlab.com/g/p/-/issues/1'
  'https://gitlab.com//p/-/merge_requests/1'
  'http://gitlab.com/g/p/-/merge_requests/1'
  'https://github.com/o/r/pull/1/'
  ' https://github.com/o/r/pull/1'
  'https://github.com/o/r/pull/1 '
  'https://github.com/o /r/pull/1'
  $'https://github.com/o/r/pull/1\t'
  $'https://github.com/o/r/pull/1\r'
  $'https://github.com/o/r/pull/1\nnext'
  $'https://github.com/o/r/pull/1\001'
  $'https://github.com/o/r/pull/1\033'
  $'https://github.com/o/r/pull/1\177'
  'https://user@github.com/o/r/pull/1'
  'https://user:pass@github.com/o/r/pull/1'
  'https://github.com:443/o/r/pull/1'
  'https://github.com/o%2Fr/pull/1'
  'https://github.com/o/r/pull/1%3Fq'
  'https://github.com/o/r/pull/1%60x'
  'https://github.com/o/r/pull/1%0A'
  'https://github.com//r/pull/1'
  'https://github.com/o//pull/1'
  'https://github.com/o/r//1'
  'https://github.com/o/r/1'
  'https://github.com/o/r/pull/'
  'https://github.com/-owner/r/pull/1'
  'https://github.com/owner-/r/pull/1'
  'https://github.com/owner--name/r/pull/1'
  'https://github.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/r/pull/1'
  'https://github.com/o/./pull/1'
  'https://github.com/o/../pull/1'
  'https://github.com/o/r+z/pull/1'
  'https://github.com/o/r/pull/+1'
  'https://github.com/o/r/pull/0'
  'https://github.com/o/r/pull/-1'
  'https://github.com/o/r/pull/01'
  'https://github.com/o/r/pull/0x1'
  'https://github.com/o/r/pull/1e2'
  'https://github.com/o/r/pull/1.0'
  'https://github.com/o/r/issues/1'
  'https://github.com/o/r/x/pull/1'
  'https://github.com/o/r/pull/1/files'
  'https://github.com/o/r/pull/1?q=x'
  'https://github.com/o/r/pull/1#f'
  'https://github.com.evil/o/r/pull/1'
  'https://evilgithub.com/o/r/pull/1'
  'http://github.com/o/r/pull/1'
  'ssh://github.com/o/r/pull/1'
  '//github.com/o/r/pull/1'
  'HTTPS://github.com/o/r/pull/1'
  'https://GitHub.com/o/r/pull/1'
  'https://github.com/o$/r/pull/1'
  'https://github.com/o(/r/pull/1'
  'https://github.com/o`/r/pull/1'
  'https://github.com/o/r`/pull/1'
  'https://github.com/o/r/pull/1`'
  "https://github.com/o/'r'/pull/1"
  'https://github.com/o/"r"/pull/1'
  "https://github.com/o/r/pull/1'"
)

# shellcheck disable=SC2016 # Literal shell syntax is task-ID test data.
INVALID_IDS=(
  '../escape'
  'a/b'
  '.'
  '..'
  '.task'
  'task a'
  $'task\ta'
  $'task\na'
  'task*'
  "task'a"
  'task"a'
  'task;a'
  'task$a'
)

test_parser_matrix() {
  local id row url owner repo number host path
  while IFS='|' read -r url owner repo number; do
    [ -n "$url" ] || continue
    cs_pr_url_parse "$url" || fail "parser rejected canonical URL"
    [ "$CS_PR_PROVIDER" = github ] || fail "parser did not tag a pull request URL as github"
    [ "$CS_PR_URL" = "$url" ] || fail "parser changed canonical URL"
    [ "$CS_PR_OWNER" = "$owner" ] || fail "parser returned wrong owner"
    [ "$CS_PR_REPO" = "$repo" ] || fail "parser returned wrong repository"
    [ "$CS_PR_NUMBER" = "$number" ] || fail "parser returned wrong PR number"
  done <<'EOF'
https://github.com/a/b/pull/1|a|b|1
https://github.com/my-org/repo/pull/42|my-org|repo|42
https://github.com/Owner/repo-name_with.parts/pull/123456|Owner|repo-name_with.parts|123456
EOF
  # A canonical GitLab merge request URL still parses exactly (provider-tagged)
  # so the GitHub-only entrypoints can refuse it BY NAME instead of misreading it.
  while IFS='|' read -r url host path number; do
    [ -n "$url" ] || continue
    cs_pr_url_parse "$url" || fail "parser rejected a canonical merge request URL"
    [ "$CS_PR_PROVIDER" = gitlab ] || fail "parser did not tag a merge request URL as gitlab"
    [ "$CS_PR_HOST" = "$host" ] || fail "parser returned wrong GitLab host"
    [ "$CS_PR_PATH" = "$path" ] || fail "parser returned wrong GitLab project path"
    [ "$CS_PR_NUMBER" = "$number" ] || fail "parser returned wrong merge request number"
  done <<'EOF'
https://gitlab.com/group/project/-/merge_requests/1|gitlab.com|group/project|1
https://gitlab.example.co.uk/g/p/-/merge_requests/7|gitlab.example.co.uk|g/p|7
EOF
  for row in "${INVALID_URLS[@]}"; do
    ! cs_pr_url_parse "$row" || fail "parser accepted a rejected raw-byte URL class"
  done
  for id in -task task- task--a Task-a task_a task.a; do
    cs_pr_task_id_valid "$id" || fail "task ID validator rejected a safe lifecycle-compatible slug"
  done
  id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  cs_pr_task_id_valid "$id" || fail "operational validator rejected a path-safe legacy task ID"
  ! cs_task_id_creation_valid "$id" || fail "creation validator accepted an overlong task ID"
  pass "raw-byte parser accepts canonical URLs and rejects the adversarial matrix"
}

test_invalid_entrypoints_have_zero_side_effects() {
  local dir before after value rc
  dir=$(make_case invalid-entrypoints)
  write_task_meta "$dir"
  printf 'existing-check\n' > "$dir/home/state/task-a.check.sh"
  printf 'existing-data\n' > "$dir/home/state/task-a.pr-poll"
  chmod 0600 "$dir/home/state/task-a.check.sh" "$dir/home/state/task-a.pr-poll"

  for value in "${INVALID_URLS[@]}"; do
    before=$(state_snapshot "$dir/home/state")
    set +e
    run_check_entry "$dir" task-a "$value" > "$dir/stdout" 2> "$dir/stderr"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "direct entrypoint accepted invalid URL"
    [ "$(cat "$dir/stderr")" = 'error: invalid PR check request' ] || fail "direct invalid URL diagnostic was not fixed"
    after=$(state_snapshot "$dir/home/state")
    [ "$after" = "$before" ] || fail "direct invalid URL changed prior state"
  done

  for value in "${INVALID_IDS[@]}"; do
    before=$(state_snapshot "$dir/home/state")
    set +e
    run_check_entry "$dir" "$value" https://github.com/o/r/pull/1 > "$dir/stdout" 2> "$dir/stderr"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "direct entrypoint accepted invalid task ID"
    after=$(state_snapshot "$dir/home/state")
    [ "$after" = "$before" ] || fail "invalid task ID changed state or traversed a path"
  done

  set +e
  run_check_entry "$dir" > /dev/null 2> "$dir/stderr"; rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "direct entrypoint accepted zero arguments"
  set +e
  run_check_entry "$dir" task-a https://github.com/o/r/pull/1 extra > /dev/null 2> "$dir/stderr"; rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "direct entrypoint accepted extra arguments"

  [ ! -s "$dir/gh.log" ] || fail "invalid check data called gh"
  [ ! -s "$dir/guard.log" ] || fail "invalid check data called the guard"
  [ ! -e "$TMP_ROOT/escape.check.sh" ] || fail "task traversal wrote outside state"
  pass "the PR check entrypoint rejects invalid arguments before every side effect"
}

test_gitlab_url_refused_loudly_with_zero_side_effects() {
  local dir before after rc
  dir=$(make_case gitlab-refusal)
  write_task_meta "$dir"
  before=$(state_snapshot "$dir/home/state")
  set +e
  run_check_entry "$dir" task-a 'https://gitlab.com/group/project/-/merge_requests/12' \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "gitlab-refusal: cs-pr-check should refuse a GitLab merge request URL"
  assert_grep 'GitLab merge requests are not supported' "$dir/stderr" \
    "gitlab-refusal: refusal did not name GitLab as unsupported (silent misparse risk)"
  after=$(state_snapshot "$dir/home/state")
  [ "$after" = "$before" ] || fail "gitlab-refusal: refused GitLab URL changed state"
  [ ! -s "$dir/gh.log" ] || fail "gitlab-refusal: refused GitLab URL called gh"
  [ ! -s "$dir/guard.log" ] || fail "gitlab-refusal: refused GitLab URL called the guard"
  assert_absent "$dir/home/state/task-a.check.sh" "gitlab-refusal: a GitLab URL armed a merge poll"
  pass "a valid GitLab merge request URL is refused loudly with zero side effects"
}

test_valid_recording_and_artifacts() {
  local dir expected sidecar count
  dir=$(make_case valid-recording)
  write_task_meta "$dir"
  expected=0123456789abcdef0123456789abcdef01234567
  CS_TEST_GH_HEAD=$expected run_check_entry "$dir" task-a https://github.com/my-org/repo_name.with-dots/pull/37 \
    > "$dir/stdout" 2> "$dir/stderr" || fail "valid direct check failed: $(cat "$dir/stderr")"

  assert_grep 'armed: state/task-a.check.sh' "$dir/stdout" "arming confirmation line missing"
  grep -qxF 'pr=https://github.com/my-org/repo_name.with-dots/pull/37' "$dir/home/state/task-a.meta" \
    || fail "canonical pr metadata was not exact"
  grep -qxF "pr_head=$expected" "$dir/home/state/task-a.meta" || fail "PR head metadata was not exact"
  cmp -s "$POLL" "$dir/home/state/task-a.check.sh" || fail "published check was not byte-for-byte static"
  [ "$(file_mode "$dir/home/state/task-a.check.sh")" = 600 ] || fail "published check mode was not 0600"
  [ "$(file_mode "$dir/home/state/task-a.pr-poll")" = 600 ] || fail "published sidecar mode was not 0600"
  [ "$(file_mode "$dir/home/state/task-a.pr-poll-registration")" = 600 ] \
    || fail "published registration mode was not 0600"
  [ "$(cs_pr_file_link_count "$dir/home/state/task-a.check.sh")" = 1 ] \
    && [ "$(cs_pr_file_link_count "$dir/home/state/task-a.pr-poll")" = 1 ] \
    && [ "$(cs_pr_file_link_count "$dir/home/state/task-a.pr-poll-registration")" = 1 ] \
    || fail "published poll artifacts were not single-link files"
  # The REAL watcher validation must accept the publication (the same function
  # bin/cs-watch.sh authenticates with before dispatching the poll).
  cs_pr_poll_artifacts_valid "$dir/home/state" task-a "$POLL" \
    || fail "published poll provenance or metadata binding failed the real watcher validation"
  sidecar=$(cat "$dir/home/state/task-a.pr-poll")
  [ "$sidecar" = $'github\nhttps://github.com/my-org/repo_name.with-dots/pull/37\ngithub.com\nmy-org/repo_name.with-dots\n37\n0123456789abcdef0123456789abcdef01234567\nhold' ] \
    || fail "published sidecar bytes were not exact"
  [ -s "$dir/guard.log" ] || fail "arming did not run the guard"

  CS_TEST_GH_HEAD=$expected run_check_entry "$dir" task-a https://github.com/my-org/repo_name.with-dots/pull/37 \
    >/dev/null 2>/dev/null || fail "valid duplicate check failed"
  count=$(grep -c '^pr=' "$dir/home/state/task-a.meta")
  [ "$count" -eq 1 ] || fail "duplicate pr metadata was appended"
  count=$(grep -c '^pr_head=' "$dir/home/state/task-a.meta")
  [ "$count" -eq 1 ] || fail "duplicate pr_head metadata was appended"

  dir=$(make_case newline-head)
  write_task_meta "$dir"
  CS_TEST_GH_HEAD=$'0123456789abcdef0123456789abcdef01234567\npane=unexpected' \
    run_check_entry "$dir" task-a https://github.com/o/r/pull/2 >/dev/null 2>/dev/null \
    || fail "valid check with malformed remote head failed"
  assert_no_grep 'pr_head=' "$dir/home/state/task-a.meta" "multiline PR head reached metadata"
  assert_no_grep 'pane=unexpected' "$dir/home/state/task-a.meta" "newline metadata key was injected"
  pass "valid direct flow records exact metadata, republishes idempotently, and rejects multiline head data"
}

test_release_policy_records_reviewed_green_attestation() {
  local dir expected sidecar project
  dir=$(make_case release-attestation)
  project="$dir/home/projects/proj"
  mkdir -p "$project" "$dir/home/data"
  expected=0123456789abcdef0123456789abcdef01234567
  cs_write_meta "$dir/home/state/task-a.meta" \
    "pane=cs-task-a" \
    "worktree=$dir/wt" \
    "project=$project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "issue=42"
  printf '%s\n%s\n' \
    '# Active board sweeps. Owned by bin/cs-board-watch.sh; do not hand-edit.' \
    'proj 5 1800 release-green-prs 2026-08-08T00:00:00Z' \
    > "$dir/home/data/sweeps.md"

  CS_TEST_GH_HEAD=$expected run_check_entry "$dir" task-a https://github.com/o/r/pull/42 \
    > "$dir/stdout" 2> "$dir/stderr" \
    || fail "release-attestation: cs-pr-check failed: $(cat "$dir/stderr")"
  assert_grep 'capacity=release-reviewed-green' "$dir/stdout" \
    "release-attestation: arming output did not report the attestation"
  sidecar=$(cat "$dir/home/state/task-a.pr-poll")
  [ "$sidecar" = $'github\nhttps://github.com/o/r/pull/42\ngithub.com\no/r\n42\n0123456789abcdef0123456789abcdef01234567\nrelease-reviewed-green' ] \
    || fail "release-attestation: authenticated sidecar did not carry exact head and release token"
  cs_pr_poll_artifacts_valid "$dir/home/state" task-a "$POLL" \
    || fail "release-attestation: real artifact validator rejected the release record"
  pass "an armed board policy records one authenticated reviewed-green release attestation"
}

test_missing_meta_refuses_before_arming() {
  local dir rc
  dir=$(make_case missing-meta)
  set +e
  run_check_entry "$dir" no-such-task https://github.com/o/r/pull/8 > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "missing-meta: cs-pr-check should refuse"
  assert_grep 'error: task metadata is unavailable' "$dir/stderr" "missing-meta: refusal did not explain missing meta"
  assert_absent "$dir/home/state/no-such-task.check.sh" "missing-meta: a poll was armed for an unknown task"
  assert_absent "$dir/home/state/no-such-task.pr-poll" "missing-meta: a sidecar was published for an unknown task"
  pass "cs-pr-check refuses when task metadata is missing, before arming anything"
}

test_atomic_interruption_leaves_no_partial_artifact() {
  local dir rc
  dir=$(make_case interrupted-write)
  write_task_meta "$dir"
  cat > "$dir/fakebin/cp" <<SH
#!/usr/bin/env bash
'$REAL_CP' "\$@" || exit 1
kill -TERM "\$PPID"
exit 0
SH
  chmod +x "$dir/fakebin/cp"

  set +e
  run_check_entry "$dir" task-a https://github.com/o/r/pull/1 > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "interrupted publication unexpectedly succeeded"
  [ ! -e "$dir/home/state/task-a.check.sh" ] || fail "interrupted publication left a runnable check"
  [ ! -e "$dir/home/state/task-a.pr-poll" ] || fail "interrupted publication left a sidecar"
  [ ! -e "$dir/home/state/task-a.pr-poll-registration" ] \
    || fail "interrupted publication left a registration"
  ! find "$dir/home/state" -name '.cs-pr-poll-*' -print | grep . >/dev/null \
    || fail "interrupted publication left temporary files"
  assert_no_grep 'pr=' "$dir/home/state/task-a.meta" "interrupted preparation changed metadata"
  pass "interrupted atomic preparation cleans private temporaries and publishes nothing"
}

# --- byte-static poll contract ------------------------------------------------

make_poll_fixture() {
  local dir=$1
  cp "$POLL" "$dir/home/state/task-a.check.sh"
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    github https://github.com/o/r/pull/1 github.com o/r 1 \
    0123456789abcdef0123456789abcdef01234567 hold \
    > "$dir/home/state/task-a.pr-poll"
  chmod 0600 "$dir/home/state/task-a.check.sh" "$dir/home/state/task-a.pr-poll"
}

run_poll() {
  local dir=$1
  CS_TEST_GH_LOG="$dir/gh.log" PATH="$dir/fakebin:$BASE_PATH" \
    bash "$dir/home/state/task-a.check.sh"
}

test_static_poll_contract() {
  local dir state value out
  dir=$(make_case poll-contract)
  make_poll_fixture "$dir"

  for state in OPEN CLOSED EMPTY MALFORMED; do
    case "$state" in
      EMPTY) value= ;;
      MALFORMED) value='not-a-state' ;;
      *) value=$state ;;
    esac
    out=$(CS_TEST_GH_STATE="$value" run_poll "$dir")
    [ -z "$out" ] || fail "static poll emitted for non-merged state"
  done
  out=$(CS_TEST_GH_STATE=MERGED run_poll "$dir")
  [ "$out" = merged ] || fail "static poll did not emit exactly one merged line"
  out=$(CS_TEST_GH_FAIL=1 run_poll "$dir")
  [ -z "$out" ] || fail "static poll emitted after gh failure"

  mv "$dir/home/state/task-a.pr-poll" "$dir/home/state/task-a.pr-poll.missing"
  out=$(run_poll "$dir")
  [ -z "$out" ] || fail "static poll emitted with missing sidecar"
  mv "$dir/home/state/task-a.pr-poll.missing" "$dir/home/state/task-a.pr-poll"
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    github https://github.com/o/r/pull/1 github.com o/r 1 \
    0123456789abcdef0123456789abcdef01234567 hold extra \
    > "$dir/home/state/task-a.pr-poll"
  out=$(CS_TEST_GH_STATE=MERGED run_poll "$dir")
  [ -z "$out" ] || fail "static poll emitted with multiline sidecar"
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    github https://github.com/o/r/pull/1x github.com o/r 1x \
    0123456789abcdef0123456789abcdef01234567 hold \
    > "$dir/home/state/task-a.pr-poll"
  out=$(CS_TEST_GH_STATE=MERGED run_poll "$dir")
  [ -z "$out" ] || fail "static poll emitted with malformed numeric data"
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    github https://github.com/other/r/pull/1 github.com o/r 1 \
    0123456789abcdef0123456789abcdef01234567 hold \
    > "$dir/home/state/task-a.pr-poll"
  out=$(CS_TEST_GH_STATE=MERGED run_poll "$dir")
  [ -z "$out" ] || fail "static poll emitted for a sidecar whose URL does not reconstruct from its parts"
  pass "static poll is silent except for exactly one merged line on a valid GitHub sidecar"
}

test_static_poll_gitlab_sidecar_stays_silent() {
  local dir out
  dir=$(make_case poll-gitlab-silent)
  cp "$POLL" "$dir/home/state/task-a.check.sh"
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    gitlab https://gitlab.com/g/p/-/merge_requests/1 gitlab.com g/p 1 \
    0123456789abcdef0123456789abcdef01234567 hold \
    > "$dir/home/state/task-a.pr-poll"
  chmod 0600 "$dir/home/state/task-a.check.sh" "$dir/home/state/task-a.pr-poll"
  # Consigliere drops GitLab merge-watch: a hand-crafted gitlab sidecar must
  # keep the poll silent (never a fabricated merged line, never a glab call).
  out=$(CS_TEST_GH_STATE=MERGED run_poll "$dir")
  [ -z "$out" ] || fail "static poll emitted for a gitlab-tagged sidecar"
  [ ! -s "$dir/gh.log" ] || fail "a gitlab-tagged sidecar reached gh"
  out=$(CS_TEST_GH_LOG="$dir/gh.log" PATH="$dir/fakebin:$BASE_PATH" \
    bash "$POLL" --validated gitlab https://gitlab.com/g/p/-/merge_requests/1 gitlab.com g/p 1)
  [ -z "$out" ] || fail "validated dispatch emitted for a gitlab identity"
  pass "a gitlab-tagged sidecar keeps the byte-static poll silent (GitLab merge-watch is dropped)"
}

test_parser_matrix
test_invalid_entrypoints_have_zero_side_effects
test_gitlab_url_refused_loudly_with_zero_side_effects
test_valid_recording_and_artifacts
test_release_policy_records_reviewed_green_attestation
test_missing_meta_refuses_before_arming
test_atomic_interruption_leaves_no_partial_artifact
test_static_poll_contract
test_static_poll_gitlab_sidecar_stays_silent
