#!/usr/bin/env bash
# Behavior tests for bin/cs-crew-state.sh - the deterministic soldier-current-
# state helper.
#
# The status file (state/<id>.status) is a best-effort append-only EVENT LOG, so
# `tail -1` of it reports the last event, not the current state. cs-crew-state
# reads the AUTHORITATIVE source (a matching made pipeline run-step via `made
# run list --json`, else the pane busy-signature) and reconciles the possibly-
# stale log against it. These cases pin every branch of that logic,
# hermetically, over real throwaway git repos with a fake `made` (run-step
# source, JSON shaped like made's real StatusReport/run-list output,
# docs/made.md) and a fake `herdr` (pane source):
#   (a) active run-step is authoritative                          -> run-step
#   (b) needs-decision/blocked log + resumed run = SUPERSEDED     -> run-step
#   (c) genuine parked (awaiting_review) run + needs-decision log
#       = NOT superseded                                          -> run-step
#   (d) terminal run-step (succeeded/failed/awaiting_merge/
#       canceled/superseded) is authoritative                     -> run-step
#   (e) branch filtering: this branch's own run found among other branches'
#       rows in one `run list --json` listing, never misattributed
#   (f) no run + busy pane                                        -> pane
#   (g) no run + idle pane falls to the status-log verb           -> status-log
#   (h) dead pane: no run -> unknown/none; with a run -> run-step (not the shell)
#   (i) kind=scout skips the run lookup                           -> pane/status-log
#   (j) torn-down worktree / missing meta                         -> unknown/none
#   (k) crew_is_provably_working end-to-end over the REAL helper (not a canned
#       fake cs-crew-state.sh verdict): this branch's own run found among
#       others -> absorbed; genuinely no run anywhere + idle pane -> surfaced.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/cs-classify-lib.sh
. "$ROOT/bin/cs-classify-lib.sh"

command -v jq >/dev/null 2>&1 || fail "jq is required (cs-crew-state.sh parses made run list --json with it)"

CREW_STATE="$ROOT/bin/cs-crew-state.sh"
TMP_ROOT=$(cs_test_tmproot cs-crew-state)
cs_git_identity cstest cstest@example.invalid

# A real git repo checked out on <branch>, so the helper's branch attribution
# (git symbolic-ref) resolves like it would for a live soldier worktree.
make_repo_on_branch() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
}

# A fakebin with a fake `made` (serves `run list --json [--active]` from
# CS_FAKE_RUN_LIST_JSON - the same listing for both, since cs_made_resolve_run's
# two-pass fallback only needs SOME well-formed answer to resolve against, not
# real --active filtering semantics, which bin/cs-made-run-lib.sh's own tests
# already pin) and a fake `herdr` (serves a live/dead pane, its rendered text,
# and the native agent status). The fake herdr tolerates the trailing
# `--session <name>` cs_herdr always appends.
make_fakebin() {  # <dir> -> echoes fakebin path
  local dir=$1 fb
  fb=$(cs_fakebin "$dir")
  cat > "$fb/made" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "run list")
    printf '%s\n' "${CS_FAKE_RUN_LIST_JSON:-}" ;;
esac
exit 0
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  pane)
    case "${2:-}" in
      get)
        [ "${CS_FAKE_HERDR_MISSING:-0}" = 1 ] && exit 1
        printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}"
        exit 0 ;;
      read)
        [ "${CS_FAKE_HERDR_MISSING:-0}" = 1 ] && exit 1
        if [ "${CS_FAKE_HERDR_BUSY:-0}" = 1 ]; then printf 'work in progress\nesc to interrupt\n'
        else printf 'all quiet\n> \n'; fi
        exit 0 ;;
      process-info)
        # CS_FAKE_HERDR_PROC: agent = an agent process runs here; husk = the
        # table reads cleanly with no agent; unset = process-info unavailable,
        # the case the husk predicate must fail closed on.
        case "${CS_FAKE_HERDR_PROC:-}" in
          agent) printf '{"result":{"process_info":{"shell_pid":10,"foreground_processes":[{"pid":11,"argv0":"codex"}]}}}\n'; exit 0 ;;
          husk)  printf '{"result":{"process_info":{"shell_pid":10,"foreground_processes":[{"pid":12,"argv0":"bash"}]}}}\n'; exit 0 ;;
          *) exit 1 ;;
        esac ;;
    esac ;;
  agent)
    case "${2:-}" in
      get)
        [ "${CS_FAKE_HERDR_MISSING:-0}" = 1 ] && exit 1
        [ -n "${CS_FAKE_HERDR_AGENT_STATUS:-}" ] || exit 1
        printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$CS_FAKE_HERDR_AGENT_STATUS"
        exit 0 ;;
    esac ;;
esac
exit 0
SH
  chmod +x "$fb/made" "$fb/herdr"
  printf '%s\n' "$fb"
}

make_no_timeout_toolbin() {  # <dir> -> echoes toolbin path
  local dir=$1 tb="$1/notimeoutbin" tool real
  mkdir -p "$tb"
  for tool in bash git grep sed awk head cut tail dirname perl jq; do
    real=$(command -v "$tool" || true)
    [ -n "$real" ] || fail "missing tool for no-timeout path: $tool"
    ln -s "$real" "$tb/$tool"
  done
  printf '%s\n' "$tb"
}

# Run the helper for one case dir. CS_FAKE_* env (run output, busy flag) are
# read from the caller's environment by the fakes above.
run_crew_state() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" CS_STATE_OVERRIDE="$1/state" "$CREW_STATE" "$2"
}

new_case() {  # <name> -> echoes case dir with an empty state/
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s\n' "$d"
}

# Clear the fake-driver vars and (re-)mark them exported, so the per-test plain
# assignments below stay exported into the fakes without an `export VAR=$(...)`
# command-substitution assignment (SC2155).
reset_fakes() {
  CS_FAKE_RUN_LIST_JSON=""
  CS_FAKE_HERDR_BUSY=0
  CS_FAKE_HERDR_MISSING=0
  CS_FAKE_HERDR_AGENT_STATUS=""
  CS_FAKE_HERDR_PROC=""
  export CS_FAKE_RUN_LIST_JSON
  export CS_FAKE_HERDR_BUSY CS_FAKE_HERDR_MISSING CS_FAKE_HERDR_AGENT_STATUS CS_FAKE_HERDR_PROC
}

# --- run-object fixtures (made's real StatusReport/run-list schema,
# docs/made.md: schema_version, run_id, repo, branch, state, input_sha,
# output_sha, execution_finished, error, errors[], pr_url,
# stages[]{name,result}, pending_findings[]{stage,message}) -----------------
#
# Only the fields each scenario actually exercises are populated - jq reads a
# missing/empty array the same as one that lists every one of made's 9
# pipeline stages, so a minimal fixture pins the same behavior as a complete
# one without restating stage names no test cares about.

findings_json() {  # <stage> <count>
  local stage=$1 count=$2 i=0 out="["
  while [ "$i" -lt "$count" ]; do
    [ "$i" -eq 0 ] || out="$out,"
    out="$out{\"stage\":\"$stage\",\"message\":\"finding $i needs a decision\"}"
    i=$((i + 1))
  done
  printf '%s]' "$out"
}

# true for the states made's own execution_finished reports true for
# (docs/made.md): awaiting_merge plus the 4 terminal states.
exec_finished_for() {
  case "$1" in
    awaiting_merge|succeeded|failed|canceled|superseded) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

# One StatusReport row. <branch> <head> <state> [<stages-json>] [<findings-json>]
# [<error>] [<errors-json>] [<pr_url>] [<queued_at>]
run_row_json() {
  local branch=$1 head=$2 state=$3 stages=${4:-[]} findings=${5:-[]} err=${6:-} \
    errs=${7:-[]} pr=${8:-} qat=${9:-2026-07-02T22:00:00Z}
  printf '{"schema_version":1,"run_id":"01RUN","repo":"o/r","branch":"%s","state":"%s","input_sha":"%s","output_sha":"%s","execution_finished":%s,"error":"%s","errors":%s,"pr_url":"%s","queued_at":"%s","stages":%s,"pending_findings":%s}\n' \
    "$branch" "$state" "$head" "$head" "$(exec_finished_for "$state")" "$err" "$errs" "$pr" "$qat" "$stages" "$findings"
}

# A {"runs":[...]} listing from N row JSON args.
run_list_json() {
  local IFS=,
  printf '{"schema_version":1,"protocol_version":1,"runs":[%s]}\n' "$*"
}

run_queued() { run_list_json "$(run_row_json "$1" "$2" queued)"; }  # <branch> <head>

run_active() { run_list_json "$(run_row_json "$1" "$2" running "[{\"name\":\"$3\",\"result\":\"pending\"}]")"; }  # <branch> <head> <stage>

run_parked() {  # <branch> <head> <gate-stage> <finding-count>
  run_list_json "$(run_row_json "$1" "$2" awaiting_review "[{\"name\":\"$3\",\"result\":\"pending\"}]" "$(findings_json "$3" "$4")")"
}

run_completed() { run_list_json "$(run_row_json "$1" "$2" succeeded)"; }  # <branch> <head>

run_failed() {  # <branch> <head> [<failed-stage>] [<error>]
  local branch=$1 head=$2 stage=${3:-} err=${4:-}
  local stages=[]
  [ -n "$stage" ] && stages="[{\"name\":\"$stage\",\"result\":\"fail\"}]"
  run_list_json "$(run_row_json "$branch" "$head" failed "$stages" [] "$err")"
}

run_ci_pending() { run_list_json "$(run_row_json "$1" "$2" running '[{"name":"ci","result":"pending"}]')"; }  # <branch> <head>

run_ci_passed() { run_list_json "$(run_row_json "$1" "$2" running '[{"name":"ci","result":"pass"}]')"; }  # <branch> <head>

run_awaiting_merge() { run_list_json "$(run_row_json "$1" "$2" awaiting_merge [] [] "" [] "${3:-}")"; }  # <branch> <head> [<pr_url>]

run_canceled() { run_list_json "$(run_row_json "$1" "$2" canceled)"; }  # <branch> <head>

run_superseded() { run_list_json "$(run_row_json "$1" "$2" superseded)"; }  # <branch> <head>

# ---------------------------------------------------------------------------
# (a) active run-step is authoritative
test_active_run_is_authoritative() {
  reset_fakes
  local d head; d=$(new_case active)
  make_repo_on_branch "$d/wt" cs/feat-a
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-a.meta" "pane=p-feat-a" "workspace=w-feat-a" "worktree=$d/wt" "kind=ship"
  CS_FAKE_RUN_LIST_JSON="$(run_active cs/feat-a "$head" review)"
  local out; out=$(run_crew_state "$d" feat-a)
  assert_contains "$out" "state: working" "active run -> working"
  assert_contains "$out" "source: run-step" "active run -> run-step source"
  assert_contains "$out" "validating (review)" "active run reports the active stage"
  pass "active run-step is authoritative"
}

test_active_run_queued_is_working() {
  reset_fakes
  local d head; d=$(new_case queued)
  make_repo_on_branch "$d/wt" cs/feat-q
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-q.meta" "pane=p-feat-q" "workspace=w-feat-q" "worktree=$d/wt" "kind=ship"
  CS_FAKE_RUN_LIST_JSON="$(run_queued cs/feat-q "$head")"
  local out; out=$(run_crew_state "$d" feat-q)
  assert_contains "$out" "state: working" "queued run -> working"
  assert_contains "$out" "source: run-step" "queued run -> run-step source"
  assert_contains "$out" "run queued" "queued run reports queued detail"
  pass "queued run-step reads as working"
}

# (b) needs-decision log + a resumed (active) run = SUPERSEDED
test_stale_needs_decision_superseded() {
  reset_fakes
  local d head; d=$(new_case superseded)
  make_repo_on_branch "$d/wt" cs/feat-b
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-b.meta" "pane=p-feat-b" "workspace=w-feat-b" "worktree=$d/wt" "kind=ship"
  printf 'working: started\nneeds-decision: pick A or B\n' > "$d/state/feat-b.status"
  CS_FAKE_RUN_LIST_JSON="$(run_active cs/feat-b "$head" test)"
  local out; out=$(run_crew_state "$d" feat-b)
  assert_contains "$out" "state: working" "resumed run -> working despite needs-decision log"
  assert_contains "$out" "source: run-step" "resumed run -> run-step source"
  assert_contains "$out" "superseded" "stale needs-decision log flagged superseded"
  pass "stale needs-decision over active run is superseded"
}

# blocked log + a resumed run is also superseded
test_stale_blocked_superseded() {
  reset_fakes
  local d head; d=$(new_case superseded-blocked)
  make_repo_on_branch "$d/wt" cs/feat-bb
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-bb.meta" "pane=p-feat-bb" "workspace=w-feat-bb" "worktree=$d/wt" "kind=ship"
  printf 'blocked: waiting on review answer\n' > "$d/state/feat-bb.status"
  CS_FAKE_RUN_LIST_JSON="$(run_active cs/feat-bb "$head" review)"
  local out; out=$(run_crew_state "$d" feat-bb)
  assert_contains "$out" "state: working" "resumed run -> working despite blocked log"
  assert_contains "$out" "superseded" "stale blocked log flagged superseded"
  pass "stale blocked over active run is superseded"
}

# needs-review differs from a pipeline gate: the existence of any attributed
# run proves the pre-validation review was acted on, even when that run is now
# parked at a later gate.
test_needs_review_superseded_once_run_exists() {
  reset_fakes
  local d head; d=$(new_case needs-review-run-exists)
  make_repo_on_branch "$d/wt" cs/feat-review-run
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-review-run.meta" "pane=p-feat-review-run" "workspace=w-feat-review-run" "worktree=$d/wt" "kind=ship"
  printf 'needs-review [key=pre-validation]: implementation committed\n' > "$d/state/feat-review-run.status"
  CS_FAKE_RUN_LIST_JSON="$(run_parked cs/feat-review-run "$head" review 2)"
  local out; out=$(run_crew_state "$d" feat-review-run)
  assert_contains "$out" "state: parked" "later parked run remains parked"
  assert_contains "$out" "source: run-step" "run existence is authoritative"
  assert_contains "$out" "superseded" "needs-review is superseded once any run exists"
  pass "needs-review is superseded once a validation run exists"
}

# (c) genuine parked (awaiting_review) run + needs-decision log AGREE -> parked, NOT superseded
test_genuine_parked_not_superseded() {
  reset_fakes
  local d head; d=$(new_case parked)
  make_repo_on_branch "$d/wt" cs/feat-c
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-c.meta" "pane=p-feat-c" "workspace=w-feat-c" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-c.status"
  CS_FAKE_RUN_LIST_JSON="$(run_parked cs/feat-c "$head" review 2)"
  local out; out=$(run_crew_state "$d" feat-c)
  assert_contains "$out" "state: parked" "genuine parked run -> parked"
  assert_contains "$out" "source: run-step" "parked -> run-step source"
  assert_contains "$out" "parked at review" "parked names the gate stage"
  assert_contains "$out" "2 finding(s)" "parked includes gate finding count"
  assert_contains "$out" "ask-user" "parked surfaces the ask-user marker"
  assert_not_contains "$out" "superseded" "agreeing parked+needs-decision not flagged stale"
  pass "genuine parked run is not flagged superseded"
}

# (d) terminal run-step is authoritative
test_terminal_completed() {
  reset_fakes
  local d head; d=$(new_case completed)
  make_repo_on_branch "$d/wt" cs/feat-d
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-d.meta" "pane=p-feat-d" "workspace=w-feat-d" "worktree=$d/wt" "kind=ship"
  CS_FAKE_RUN_LIST_JSON="$(run_completed cs/feat-d "$head")"
  local out; out=$(run_crew_state "$d" feat-d)
  assert_contains "$out" "state: done" "succeeded run -> done"
  assert_contains "$out" "source: run-step" "succeeded -> run-step source"
  pass "terminal succeeded run is authoritative"
}

test_terminal_failed() {
  reset_fakes
  local d head; d=$(new_case failed)
  make_repo_on_branch "$d/wt" cs/feat-e
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-e.meta" "pane=p-feat-e" "workspace=w-feat-e" "worktree=$d/wt" "kind=ship"
  CS_FAKE_RUN_LIST_JSON="$(run_failed cs/feat-e "$head" test "exit status 1")"
  local out; out=$(run_crew_state "$d" feat-e)
  assert_contains "$out" "state: failed" "failed run -> failed"
  assert_contains "$out" "source: run-step" "failed -> run-step source"
  assert_contains "$out" "exit status 1" "failed detail carries the error message"
  pass "terminal failed run is authoritative"
}

test_terminal_failed_names_stage_without_error() {
  reset_fakes
  local d head; d=$(new_case failed-no-error)
  make_repo_on_branch "$d/wt" cs/feat-ee
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-ee.meta" "pane=p-feat-ee" "workspace=w-feat-ee" "worktree=$d/wt" "kind=ship"
  CS_FAKE_RUN_LIST_JSON="$(run_failed cs/feat-ee "$head" lint)"
  local out; out=$(run_crew_state "$d" feat-ee)
  assert_contains "$out" "state: failed" "failed run with no error message -> failed"
  assert_contains "$out" "run failed at lint" "failed detail names the failing stage"
  pass "a failed run with no error message still names the failing stage"
}

test_failed_run_surfaces_plural_errors_array() {
  reset_fakes
  local d head row; d=$(new_case failed-errors-array)
  make_repo_on_branch "$d/wt" cs/feat-errs
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-errs.meta" "pane=p-feat-errs" "workspace=w-feat-errs" "worktree=$d/wt" "kind=ship"
  row=$(run_row_json cs/feat-errs "$head" failed [] [] "" '["lint: 2 issues","test: timeout"]')
  CS_FAKE_RUN_LIST_JSON="$(run_list_json "$row")"
  local out; out=$(run_crew_state "$d" feat-errs)
  assert_contains "$out" "state: failed" "failed run with a plural errors[] array -> failed"
  assert_contains "$out" "run failed: lint: 2 issues; test: timeout" "failed detail joins the errors[] array when .error is empty"
  pass "a failed run with an empty singular error falls back to the plural errors[] array"
}

test_awaiting_merge_reports_done_with_pr_url() {
  reset_fakes
  local d head; d=$(new_case awaiting-merge)
  make_repo_on_branch "$d/wt" cs/feat-merge
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-merge.meta" "pane=p-feat-merge" "workspace=w-feat-merge" "worktree=$d/wt" "kind=ship"
  CS_FAKE_RUN_LIST_JSON="$(run_awaiting_merge cs/feat-merge "$head" https://github.com/o/r/pull/9)"
  local out; out=$(run_crew_state "$d" feat-merge)
  assert_contains "$out" "state: done" "awaiting_merge run -> done"
  assert_contains "$out" "source: run-step" "awaiting_merge -> run-step source"
  assert_contains "$out" "https://github.com/o/r/pull/9" "awaiting_merge detail carries the PR url"
  pass "an awaiting_merge run reports done with the PR url"
}

test_canceled_reports_failed() {
  reset_fakes
  local d head; d=$(new_case canceled)
  make_repo_on_branch "$d/wt" cs/feat-canceled
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-canceled.meta" "pane=p-feat-canceled" "workspace=w-feat-canceled" "worktree=$d/wt" "kind=ship"
  CS_FAKE_RUN_LIST_JSON="$(run_canceled cs/feat-canceled "$head")"
  local out; out=$(run_crew_state "$d" feat-canceled)
  assert_contains "$out" "state: failed" "canceled run -> failed"
  assert_contains "$out" "run cancelled" "canceled run names its detail"
  pass "a canceled run reports failed"
}

test_superseded_reports_stale() {
  reset_fakes
  local d head; d=$(new_case superseded-state)
  make_repo_on_branch "$d/wt" cs/feat-superseded
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-superseded.meta" "pane=p-feat-superseded" "workspace=w-feat-superseded" "worktree=$d/wt" "kind=ship"
  CS_FAKE_RUN_LIST_JSON="$(run_superseded cs/feat-superseded "$head")"
  local out; out=$(run_crew_state "$d" feat-superseded)
  assert_contains "$out" "state: stale" "superseded run -> stale"
  assert_contains "$out" "source: run-step" "superseded -> run-step source"
  pass "a superseded run reports the new stale state"
}

# --- ci-stage-driven "checks green" detection -------------------------------
# made's per-stage `result` field replaces no-mistakes' old ci-log-tail marker
# scan: a live "pass"/"pending" read is always available, so there is no
# "insufficient data, trust the log" case left to reproduce.

test_ci_stage_pass_surfaces_done_without_a_log_line() {
  reset_fakes
  local d head; d=$(new_case ci-pass-no-log)
  make_repo_on_branch "$d/wt" cs/feat-cipass
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-cipass.meta" "pane=p-feat-cipass" "workspace=w-feat-cipass" "worktree=$d/wt" "kind=ship"
  CS_FAKE_RUN_LIST_JSON="$(run_ci_passed cs/feat-cipass "$head")"
  local out; out=$(run_crew_state "$d" feat-cipass)
  assert_contains "$out" "state: done" "a passed ci stage -> done even with no status-log confirmation"
  assert_contains "$out" "source: run-step" "ci-stage-pass detection is run-step sourced"
  assert_contains "$out" "checks green" "ci-stage-pass detail mentions checks green"
  pass "ci stage pass surfaces done straight from the live snapshot"
}

test_ci_stage_pass_and_log_agree_stays_run_step_sourced() {
  reset_fakes
  local d head; d=$(new_case ci-pass-log-agrees)
  make_repo_on_branch "$d/wt" cs/feat-cipasslog
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-cipasslog.meta" "pane=p-feat-cipasslog" "workspace=w-feat-cipasslog" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cipasslog.status"
  CS_FAKE_RUN_LIST_JSON="$(run_ci_passed cs/feat-cipasslog "$head")"
  local out; out=$(run_crew_state "$d" feat-cipasslog)
  assert_contains "$out" "state: done" "ci-stage-pass with an agreeing log -> done"
  assert_contains "$out" "source: run-step" "the live stage result wins over a duplicate log confirmation"
  pass "a passed ci stage does not need the log's agreement to report done"
}

test_ci_stage_pending_ignores_a_stale_done_log() {
  reset_fakes
  local d head; d=$(new_case ci-pending-stale-log)
  make_repo_on_branch "$d/wt" cs/feat-cipending
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-cipending.meta" "pane=p-feat-cipending" "workspace=w-feat-cipending" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cipending.status"
  CS_FAKE_RUN_LIST_JSON="$(run_ci_pending cs/feat-cipending "$head")"
  local out; out=$(run_crew_state "$d" feat-cipending)
  assert_contains "$out" "state: working" "a live pending ci stage is never masked by a stale done log"
  assert_contains "$out" "source: run-step" "pending ci stage remains run-step sourced"
  assert_not_contains "$out" "state: done" "pending ci stage must never read as done"
  pass "a pending ci stage overrides a stale checks-green status log"
}

test_ci_stage_pending_stays_working_without_a_log() {
  reset_fakes
  local d head; d=$(new_case ci-pending-no-log)
  make_repo_on_branch "$d/wt" cs/feat-cipendingnolog
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-cipendingnolog.meta" "pane=p-feat-cipendingnolog" "workspace=w-feat-cipendingnolog" "worktree=$d/wt" "kind=ship"
  CS_FAKE_RUN_LIST_JSON="$(run_ci_pending cs/feat-cipendingnolog "$head")"
  local out; out=$(run_crew_state "$d" feat-cipendingnolog)
  assert_contains "$out" "state: working" "pending ci stage with no log claim -> working"
  assert_not_contains "$out" "checks green" "no green marker present -> no checks-green detail"
  pass "a pending ci stage with no log claim stays working"
}

# (e) branch filtering: `made run list --json` returns rows for OTHER
# branches alongside this one (the routine case once more than one soldier
# validates the same underlying repo concurrently) - cs_made_resolve_run
# filters by branch itself, so this branch's own row is found directly in one
# listing; a cross-branch misattribution is structurally impossible.
test_cross_branch_attribution_via_runs_list() {
  reset_fakes
  local d head; d=$(new_case crossbranch)
  make_repo_on_branch "$d/wt" cs/feat-f
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-f.meta" "pane=p-feat-f" "workspace=w-feat-f" "worktree=$d/wt" "kind=ship"
  CS_FAKE_RUN_LIST_JSON="$(run_list_json \
    "$(run_row_json cs/other-soldier "$head" running)" \
    "$(run_row_json cs/feat-f "$head" running "[{\"name\":\"review\",\"result\":\"pending\"}]")")"
  local out; out=$(run_crew_state "$d" feat-f)
  assert_contains "$out" "state: working" "this branch's own run attributed via the run list"
  assert_contains "$out" "source: run-step" "run-list-resolved run -> run-step source"
  pass "this branch's own run is found among other branches' rows in one listing"
}

# Multiple rows for the SAME branch: the more recent (by queued_at) row wins,
# even when it is not the first row in the listing.
test_cross_branch_attribution_picks_most_recent_row() {
  reset_fakes
  local d head; d=$(new_case crossbranch-mostrecent)
  make_repo_on_branch "$d/wt" cs/feat-fq
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-fq.meta" "pane=p-feat-fq" "workspace=w-feat-fq" "worktree=$d/wt" "kind=ship"
  CS_FAKE_RUN_LIST_JSON="$(run_list_json \
    "$(run_row_json cs/other-soldier "$head" running [] [] "" [] "" 2026-07-02T22:10:00Z)" \
    "$(run_row_json cs/feat-fq "$head" running [] [] "" [] "" 2026-07-02T21:50:00Z)" \
    "$(run_row_json cs/feat-fq "$head" succeeded [] [] "" [] "" 2026-07-02T20:00:00Z)")"
  local out; out=$(run_crew_state "$d" feat-fq)
  assert_contains "$out" "state: working" "most recent (running) row wins over an older succeeded row"
  assert_contains "$out" "source: run-step" "most-recent-row resolution -> run-step source"
  pass "cross-branch attribution picks the branch's most recent row"
}

# A different-branch run with NO matching row for this branch must NOT be
# misattributed, and must not be treated as a false "working" verdict either.
test_other_branch_run_ignored() {
  reset_fakes
  local d head; d=$(new_case otherbranch)
  make_repo_on_branch "$d/wt" cs/feat-g
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-g.meta" "pane=p-feat-g" "workspace=w-feat-g" "worktree=$d/wt" "kind=ship"
  printf 'done: implemented, ready to validate\n' > "$d/state/feat-g.status"
  CS_FAKE_RUN_LIST_JSON="$(run_list_json "$(run_row_json cs/some-other "$head" running)")"
  CS_FAKE_HERDR_BUSY=0
  local out; out=$(run_crew_state "$d" feat-g)
  assert_not_contains "$out" "source: run-step" "another branch's run not misattributed"
  assert_contains "$out" "source: status-log" "no own run -> falls back to status-log"
  assert_contains "$out" "state: done" "falls back to the log verb"
  pass "another branch's run is ignored, falls back"
}

# A malformed/empty made answer (an unreachable daemon, a bounded call that
# times out) must degrade to "no run", never to a jq parse error.
test_malformed_status_json_falls_back() {
  reset_fakes
  local d; d=$(new_case malformed-json)
  make_repo_on_branch "$d/wt" cs/feat-malformed
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-malformed.meta" "pane=p-feat-malformed" "workspace=w-feat-malformed" "worktree=$d/wt" "kind=ship"
  printf 'done: implemented, ready to validate\n' > "$d/state/feat-malformed.status"
  CS_FAKE_RUN_LIST_JSON="not json at all"
  CS_FAKE_HERDR_BUSY=0
  local out; out=$(run_crew_state "$d" feat-malformed)
  assert_not_contains "$out" "source: run-step" "malformed made run-list output is not attributed"
  assert_contains "$out" "source: status-log" "malformed made run-list output falls back to status-log"
  pass "malformed made run list --json output falls back gracefully"
}

# (f) no run for this soldier + a busy pane -> working via pane. Native
# herdr agent status "working" is trusted outright as busy.
test_no_run_busy_pane() {
  reset_fakes
  local d; d=$(new_case busy)
  make_repo_on_branch "$d/wt" cs/feat-h
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-h.meta" "pane=p-feat-h" "workspace=w-feat-h" "worktree=$d/wt" "kind=ship"
  # No matching run anywhere.
  CS_FAKE_RUN_LIST_JSON=""
  CS_FAKE_HERDR_AGENT_STATUS=working
  local out; out=$(run_crew_state "$d" feat-h)
  assert_contains "$out" "state: working" "busy pane -> working"
  assert_contains "$out" "source: pane" "busy pane -> pane source"
  pass "no run + busy pane reads working from the pane"
}

# An UNKNOWN native agent status (agent.get failed) falls back to the rendered
# codex busy signature (cs-herdr-lib.sh's corroboration policy).
test_no_run_unknown_agent_status_uses_pane_capture() {
  reset_fakes
  local d; d=$(new_case herdr-busy)
  make_repo_on_branch "$d/wt" cs/feat-herdr
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-herdr.meta" "pane=p-feat-herdr" "workspace=w-feat-herdr" "worktree=$d/wt" "kind=ship"
  CS_FAKE_RUN_LIST_JSON=""
  CS_FAKE_HERDR_AGENT_STATUS=""
  CS_FAKE_HERDR_BUSY=1
  local out; out=$(run_crew_state "$d" feat-herdr)
  assert_contains "$out" "state: working" "herdr busy pane -> working"
  assert_contains "$out" "source: pane" "herdr busy pane -> pane source"
  pass "unknown native state falls back to pane capture busy regex"
}

# Regression: herdr's agent.get reports generation state ("working" only while
# the model is actively streaming a turn), not "this soldier's tool call is
# still in progress". A soldier blocked on its own long-running foreground
# made pipeline call (blocks until a gate or outcome) is not generating for
# that whole span, so agent.get can read idle while the pane's own rendered
# text still shows the busy banner for the entire call. `idle` must be
# corroborated with that text exactly like `unknown` is, not trusted outright
# (cs_herdr_agent_busy_state owns this policy).
test_no_run_idle_agent_status_corroborated_by_busy_pane() {
  reset_fakes
  local d; d=$(new_case herdr-idle-busy-pane)
  make_repo_on_branch "$d/wt" cs/feat-herdr-idle
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-herdr-idle.meta" "pane=p-feat-herdr-idle" "workspace=w-feat-herdr-idle" "worktree=$d/wt" "kind=ship"
  # No run attributable: the pane fallback is the only remaining signal.
  CS_FAKE_RUN_LIST_JSON=""
  CS_FAKE_HERDR_AGENT_STATUS=idle
  CS_FAKE_HERDR_BUSY=1
  local out; out=$(run_crew_state "$d" feat-herdr-idle)
  assert_contains "$out" "state: working" "idle agent_status with a busy-banner pane -> working"
  assert_contains "$out" "source: pane" "idle agent_status with a busy-banner pane -> pane source"
  pass "idle agent_status is corroborated by the pane text, not trusted outright"
}

# The corroboration must not mask a genuinely idle/human-blocked agent: idle
# agent_status AND an idle-looking pane (no busy banner) still reads not-busy.
test_no_run_idle_agent_status_and_idle_pane_stays_idle() {
  reset_fakes
  local d; d=$(new_case herdr-idle-idle-pane)
  make_repo_on_branch "$d/wt" cs/feat-herdr-stopped
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-herdr-stopped.meta" "pane=p-feat-herdr-stopped" "workspace=w-feat-herdr-stopped" "worktree=$d/wt" "kind=ship"
  printf 'working: implementing\n' > "$d/state/feat-herdr-stopped.status"
  CS_FAKE_RUN_LIST_JSON=""
  CS_FAKE_HERDR_AGENT_STATUS=idle
  CS_FAKE_HERDR_BUSY=0
  local out; out=$(run_crew_state "$d" feat-herdr-stopped)
  assert_not_contains "$out" "source: pane" "idle agent_status with an idle pane must not read as busy from the pane"
  assert_contains "$out" "source: status-log" "idle agent_status with an idle pane falls to the status log"
  pass "idle agent_status with a genuinely idle pane stays not-busy (no regression for a human-blocked agent)"
}

# (g) no run + idle pane -> the status-log verb, as-is
test_no_run_idle_pane_uses_log() {
  reset_fakes
  local d; d=$(new_case idle)
  make_repo_on_branch "$d/wt" cs/feat-i
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-i.meta" "pane=p-feat-i" "workspace=w-feat-i" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: which database?\n' > "$d/state/feat-i.status"
  CS_FAKE_RUN_LIST_JSON=""
  CS_FAKE_HERDR_BUSY=0
  local out; out=$(run_crew_state "$d" feat-i)
  assert_contains "$out" "state: parked" "needs-decision log -> parked"
  assert_contains "$out" "source: status-log" "idle pane -> status-log source"
  pass "no run + idle pane uses the status-log verb"
}

# (g'') a made soldier that committed and is waiting for consigliere to review
# it reports needs-review, which must read as PARKED, never done. This is the
# whole point of the verb: `done:` at the commit was indistinguishable from
# `done: PR ... checks green`, so a missed review looked like finished work and
# idled niceuptime-590 for 56m on 2026-08-02.
test_no_run_idle_pane_needs_review_is_parked() {
  reset_fakes
  local d; d=$(new_case needs-review)
  make_repo_on_branch "$d/wt" cs/feat-review
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-review.meta" "pane=p-feat-review" "workspace=w-feat-review" "worktree=$d/wt" "kind=ship"
  printf 'needs-review: retired the legacy flag; awaiting review before validation\n' > "$d/state/feat-review.status"
  CS_FAKE_RUN_LIST_JSON=""
  CS_FAKE_HERDR_BUSY=0
  local out; out=$(run_crew_state "$d" feat-review)
  assert_contains "$out" "state: parked" "needs-review log -> parked, not done"
  case "$out" in
    *"state: done"*) fail "needs-review must never reconcile to done" ;;
  esac
  pass "a committed-but-unreviewed lane reads as parked, not done"
}

test_needs_review_only_resolved_closes_key() {
  local d status open
  d=$(new_case needs-review-resolution)
  status="$d/state/review.status"
  printf 'needs-review [key=pre-validation]: implementation committed\n' > "$status"
  printf 'captain-held [key=pre-validation]: parked elsewhere\n' >> "$status"
  open=$(status_open_decisions "$status")
  assert_contains "$open" $'pre-validation\tneeds-review\timplementation committed' \
    "captain-held must not close a required pre-validation review"
  printf 'resolved [key=other]: unrelated decision closed\n' >> "$status"
  open=$(status_open_decisions "$status")
  assert_contains "$open" $'pre-validation\tneeds-review\timplementation committed' \
    "an unrelated resolution must not close the review key"
  printf 'resolved [key=pre-validation]: commit reviewed and validation started\n' >> "$status"
  open=$(status_open_decisions "$status")
  [ -z "$open" ] || fail "matching resolved: did not close needs-review: $open"

  printf 'needs-decision [key=route]: choose delivery route\n' > "$status"
  printf 'captain-held [key=route]: transferred to durable boss backlog\n' >> "$status"
  open=$(status_open_decisions "$status")
  [ -z "$open" ] || fail "captain-held no longer closes ordinary needs-decision: $open"
  pass "only matching resolved closes a keyed needs-review decision"
}

test_no_run_idle_pane_uses_keyed_log() {
  reset_fakes
  local d; d=$(new_case keyed-idle)
  make_repo_on_branch "$d/wt" cs/feat-keyed
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-keyed.meta" "pane=p-feat-keyed" "workspace=w-feat-keyed" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision [key=q1]: which database?\n' > "$d/state/feat-keyed.status"
  CS_FAKE_RUN_LIST_JSON=""
  CS_FAKE_HERDR_BUSY=0
  local out; out=$(run_crew_state "$d" feat-keyed)
  assert_contains "$out" "state: parked" "keyed needs-decision log -> parked"
  assert_contains "$out" "which database?" "key token is excluded from status detail"
  pass "no run + idle pane parses keyed status syntax"
}

# (g') no run + idle pane on a DECLARED external-wait pause -> state: paused, so a
# supervisor reading the soldier sees a distinct pause (and its reason) rather than
# a wedge-suspect idle. This is the reader half the watcher/daemon build on.
test_no_run_idle_pane_paused() {
  reset_fakes
  local d; d=$(new_case paused)
  make_repo_on_branch "$d/wt" cs/feat-pause
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-pause.meta" "pane=p-feat-pause" "workspace=w-feat-pause" "worktree=$d/wt" "kind=ship"
  printf 'paused: holding for the upstream tool release\n' > "$d/state/feat-pause.status"
  CS_FAKE_RUN_LIST_JSON=""
  CS_FAKE_HERDR_BUSY=0
  local out; out=$(run_crew_state "$d" feat-pause)
  assert_contains "$out" "state: paused" "paused log -> paused"
  assert_contains "$out" "source: status-log" "idle pause -> status-log source"
  assert_contains "$out" "holding for the upstream tool release" "the pause reason is carried in the detail"
  pass "no run + idle pane on a paused: status reports state: paused with its reason"
}

test_no_run_idle_pane_custom_paused_verb() {
  reset_fakes
  local d; d=$(new_case custom-paused)
  make_repo_on_branch "$d/wt" cs/feat-custom-pause
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-custom-pause.meta" "pane=p-feat-custom-pause" "workspace=w-feat-custom-pause" "worktree=$d/wt" "kind=ship"
  printf 'awaiting: vendor maintenance window\n' > "$d/state/feat-custom-pause.status"
  CS_FAKE_RUN_LIST_JSON=""
  CS_FAKE_HERDR_BUSY=0
  local out; out=$(CS_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: paused" "custom paused verb -> paused"
  assert_contains "$out" "source: status-log" "custom paused verb -> status-log source"
  assert_contains "$out" "vendor maintenance window" "custom pause preserves its reason"
  printf 'paused: default verb no longer selected\n' > "$d/state/feat-custom-pause.status"
  out=$(CS_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: unknown" "custom paused verb replaces the default"
  pass "no run + idle pane honors the configured paused verb"
}

# A trailing keyed resolved: event is a decision-CLOSING event, not a run-state
# verb. It must never become the current state or leak its resolution prose as the
# detail: a healthy idle capo that just closed a keyed decision falls through to
# the idle default (unknown/none), not `unknown` with the resolution note as its
# `doing`. The one-owner keyed fold in cs-classify-lib.sh is untouched; this only
# stops the deriver from reading a non-state event as state.
test_no_run_idle_capo_resolved_event_not_state() {
  reset_fakes
  local d; d=$(new_case resolved-idle)
  mkdir -p "$d/wt"
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/mate.meta" "pane=p-mate" "workspace=w-mate" "worktree=$d/wt" "kind=capo" "home=$d/wt"
  printf 'needs-decision [key=race]: pick subscribe order\n' > "$d/state/mate.status"
  printf 'resolved [key=race]: went with subscribe-before-write\n' >> "$d/state/mate.status"
  CS_FAKE_RUN_LIST_JSON=""
  CS_FAKE_HERDR_BUSY=0
  local out; out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: unknown" "resolved-then-idle capo is not a spurious run-state"
  assert_contains "$out" "source: none" "a resolved event is not treated as a status-log state source"
  assert_not_contains "$out" "subscribe-before-write" "resolution prose must not leak into the detail"
  # A bare (non-keyed) resolved: closes the default key and behaves the same.
  printf 'blocked: waiting on infra\nresolved: infra access granted\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "source: none" "a bare resolved: is not a state source either"
  assert_not_contains "$out" "infra access granted" "bare resolution prose must not leak into the detail"
  # Control: a genuine trailing state verb still renders from the log.
  printf 'working: reconciling routed items\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: working" "a real trailing state verb still renders"
  assert_contains "$out" "reconciling routed items" "a real state line still carries its detail"
  pass "a trailing resolved: event does not corrupt state render (idle stays idle)"
}

test_dead_pane_ignores_stale_status_log() {
  reset_fakes
  local d; d=$(new_case dead-pane)
  make_repo_on_branch "$d/wt" cs/feat-dead
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-dead.meta" "pane=p-feat-dead" "workspace=w-feat-dead" "worktree=$d/wt" "kind=ship"
  printf 'done: old completion event\n' > "$d/state/feat-dead.status"
  CS_FAKE_RUN_LIST_JSON=""
  CS_FAKE_HERDR_MISSING=1
  local out; out=$(run_crew_state "$d" feat-dead)
  assert_contains "$out" "state: unknown" "dead pane -> unknown"
  assert_contains "$out" "source: none" "dead pane -> none source"
  assert_not_contains "$out" "source: status-log" "dead pane does not reuse stale log"
  pass "dead pane ignores stale status log"
}

# A closed/unreadable pane must NOT mask an authoritative run-step: judge by the
# run-step, not the shell. The common case is a finished soldier whose agent has
# exited and closed its pane (the normal gap between completion and teardown) -
# it must still report its terminal run-step state (e.g. done), never unknown.
test_dead_pane_still_reports_terminal_run_step() {
  reset_fakes
  local d head; d=$(new_case dead-pane-done)
  make_repo_on_branch "$d/wt" cs/feat-dead-done
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-dead-done.meta" "pane=p-feat-dead-done" "workspace=w-feat-dead-done" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/3 checks green\n' > "$d/state/feat-dead-done.status"
  CS_FAKE_RUN_LIST_JSON="$(run_completed cs/feat-dead-done "$head")"
  CS_FAKE_HERDR_MISSING=1   # the soldier's pane has closed
  local out; out=$(run_crew_state "$d" feat-dead-done)
  assert_contains "$out" "state: done" "closed pane still reports terminal run-step done"
  assert_contains "$out" "source: run-step" "closed pane does not mask the run-step"
  assert_not_contains "$out" "state: unknown" "closed pane with a run must never be unknown"
  pass "closed pane still reports a terminal run-step"
}

# The same for an active run: an agent pane that crashed mid-validation while the
# daemon-backed run continues must report the live run-step, not unknown.
test_dead_pane_still_reports_active_run_step() {
  reset_fakes
  local d head; d=$(new_case dead-pane-active)
  make_repo_on_branch "$d/wt" cs/feat-dead-act
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-dead-act.meta" "pane=p-feat-dead-act" "workspace=w-feat-dead-act" "worktree=$d/wt" "kind=ship"
  CS_FAKE_RUN_LIST_JSON="$(run_active cs/feat-dead-act "$head" review)"
  CS_FAKE_HERDR_MISSING=1
  local out; out=$(run_crew_state "$d" feat-dead-act)
  assert_contains "$out" "state: working" "closed pane still reports active run-step"
  assert_contains "$out" "source: run-step" "closed pane does not mask the active run-step"
  assert_not_contains "$out" "state: unknown" "closed pane with an active run must never be unknown"
  pass "closed pane still reports an active run-step"
}

test_no_timeout_uses_perl_bound() {
  reset_fakes
  local d toolbin out start elapsed calls_file calls
  d=$(new_case no-timeout)
  make_repo_on_branch "$d/wt" cs/feat-timeout
  make_fakebin "$d" >/dev/null
  calls_file="$d/made.calls"
  : > "$calls_file"
  cat > "$d/fakebin/made" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CS_FAKE_MADE_CALLS:-/dev/null}"
while :; do :; done
SH
  chmod +x "$d/fakebin/made"
  toolbin=$(make_no_timeout_toolbin "$d")
  cs_write_meta "$d/state/feat-timeout.meta" "pane=p-feat-timeout" "workspace=w-feat-timeout" "worktree=$d/wt" "kind=ship"
  CS_FAKE_HERDR_AGENT_STATUS=working
  start=$SECONDS
  out=$(CS_FAKE_MADE_CALLS="$calls_file" PATH="$d/fakebin:$toolbin" CS_STATE_OVERRIDE="$d/state" CS_CREW_STATE_NM_TIMEOUT=1 "$CREW_STATE" feat-timeout)
  elapsed=$((SECONDS - start))
  assert_contains "$out" "state: working" "timed-out made run-list falls back to pane"
  assert_contains "$out" "source: pane" "timed-out made run-list -> pane source"
  [ "$elapsed" -lt 5 ] || fail "perl timeout did not bound the made call (elapsed ${elapsed}s)"
  calls=$(awk 'END { print NR + 0 }' "$calls_file" 2>/dev/null || echo 0)
  # The property is that a bounded lookup returning nothing is not RETRIED
  # beyond the two calls cs_made_resolve_run's active/full fallback makes, so
  # the ceiling is what matters. A lower count is a legitimate outcome of the
  # same bound: cs_run_timed forks, then alarms after the 1s this case
  # configures, and on a loaded host that alarm can fire before the forked
  # child has finished exec'ing the fake, which records its call from inside
  # the exec'd script.
  [ "$calls" -le 2 ] || fail "empty made run-list triggered extra lookups ($calls calls)"
  pass "no timeout command uses perl bound"
}

# (i) kind=scout skips the run lookup entirely (its deliverable is a report).
test_scout_skips_run_lookup() {
  reset_fakes
  local d head; d=$(new_case scout)
  make_repo_on_branch "$d/wt" cs/scout-j
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/scout-j.meta" "pane=p-scout-j" "workspace=w-scout-j" "worktree=$d/wt" "kind=scout"
  # Even if a run existed on this branch, a scout must not read it.
  CS_FAKE_RUN_LIST_JSON="$(run_active cs/scout-j "$head" review)"
  CS_FAKE_HERDR_AGENT_STATUS=working
  local out; out=$(run_crew_state "$d" scout-j)
  assert_not_contains "$out" "source: run-step" "scout ignores the made run-step"
  assert_contains "$out" "source: pane" "scout reads pane busy-signature"
  pass "scout skips the run lookup"
}

# (j) torn-down worktree and missing meta are graceful (unknown/none, exit 0)
test_torn_down_worktree() {
  reset_fakes
  local d; d=$(new_case torndown)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/gone-k.meta" "pane=p-gone-k" "workspace=w-gone-k" "worktree=$d/no-such-worktree" "kind=ship"
  local out rc
  out=$(run_crew_state "$d" gone-k); rc=$?
  expect_code 0 "$rc" "torn-down worktree exits 0"
  assert_contains "$out" "state: unknown" "torn-down -> unknown"
  assert_contains "$out" "source: none" "torn-down -> none source"
  pass "torn-down worktree is handled gracefully"
}

test_missing_meta() {
  reset_fakes
  local d; d=$(new_case nometa)
  make_fakebin "$d" >/dev/null
  local out rc
  out=$(run_crew_state "$d" ghost-z); rc=$?
  expect_code 0 "$rc" "missing meta exits 0"
  assert_contains "$out" "state: unknown" "missing meta -> unknown"
  assert_contains "$out" "source: none" "missing meta -> none source"
  pass "missing meta is handled gracefully"
}

# (k) crew_is_provably_working end-to-end over the REAL cs-crew-state.sh (not a
# canned fake verdict): a validating soldier whose own row appears alongside
# another branch's row in one `made run list --json` listing must still be
# absorbed by the watcher (working), while a soldier with genuinely no run
# anywhere and an idle pane must still surface (the safety property the
# lookup must never widen away).
test_provably_working_via_runs_list_fallback() {
  reset_fakes
  local d head; d=$(new_case provably-working-crossbranch)
  make_repo_on_branch "$d/wt" cs/feat-provable
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-provable.meta" "pane=p-feat-provable" "workspace=w-feat-provable" "worktree=$d/wt" "kind=ship"
  CS_FAKE_RUN_LIST_JSON="$(run_list_json \
    "$(run_row_json cs/other-soldier "$head" running)" \
    "$(run_row_json cs/feat-provable "$head" running)")"
  PATH="$d/fakebin:$PATH" CS_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-provable \
    || fail "this branch's own row among others was not treated as provably working"
  pass "crew_is_provably_working absorbs a validating soldier found among other branches' rows"
}

test_not_provably_working_when_stopped() {
  reset_fakes
  local d; d=$(new_case provably-working-stopped)
  make_repo_on_branch "$d/wt" cs/feat-stopped
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-stopped.meta" "pane=p-feat-stopped" "workspace=w-feat-stopped" "worktree=$d/wt" "kind=ship"
  # The listing has a row for someone else, and this branch has no row of its
  # own (it never validated, or genuinely finished/stopped) - the only
  # remaining signal is the pane, which is idle.
  head=$(git -C "$d/wt" rev-parse HEAD)
  CS_FAKE_RUN_LIST_JSON="$(run_list_json "$(run_row_json cs/other-soldier "$head" running)")"
  CS_FAKE_HERDR_BUSY=0
  PATH="$d/fakebin:$PATH" CS_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-stopped \
    && fail "a stopped soldier with no run anywhere and an idle pane was treated as provably working"
  pass "crew_is_provably_working still surfaces a genuinely stopped soldier (safety property preserved)"
}

# Usage error (no id) is the one non-zero exit.
test_usage_error() {
  reset_fakes
  local rc
  "$CREW_STATE" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "no-arg usage error exits 2"
  pass "usage error exits 2"
}

# --- head-identity safety net -----------------------------------------------
# made's real run-list rows carry both branch and head (output_sha, falling
# back to input_sha) on every row, so head identity (a reused branch name
# whose tip was rewritten or has diverged) is verified on every lookup
# (cs_made_head_matches_worktree, bin/cs-made-run-lib.sh). These pin that
# safety net.

test_historical_same_branch_rewritten_head_not_current() {
  reset_fakes
  local d old_head out
  d=$(new_case rewritten-head)
  make_repo_on_branch "$d/wt" cs/todo-flag
  old_head=$(git -C "$d/wt" rev-parse HEAD)
  # Simulate a rebase rewrite: orphan new history on the same branch name.
  git -C "$d/wt" checkout -q --orphan tmp-rewrite
  git -C "$d/wt" commit -q --allow-empty -m 'rewritten tip'
  git -C "$d/wt" branch -q -M cs/todo-flag
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/wishlist.meta" "pane=p-wishlist" "workspace=w-wishlist" "worktree=$d/wt" "kind=ship"
  printf 'working: stage 2 setup complete rebased onto merged #76\n' > "$d/state/wishlist.status"
  # The listing still lists the reused branch name at its PRE-REWRITE head,
  # the historical run's own code identity - unrelated to the new orphan tip.
  CS_FAKE_RUN_LIST_JSON="$(run_list_json "$(run_row_json cs/todo-flag "$old_head" awaiting_review)")"
  CS_FAKE_HERDR_BUSY=0
  out=$(run_crew_state "$d" wishlist)
  assert_not_contains "$out" "source: run-step" "historical rewritten head must not use run-step"
  assert_contains "$out" "source: status-log" "falls back to status-log after head mismatch"
  assert_contains "$out" "state: working" "status-log working: remains current"
  pass "historical same-branch rewritten head is not attributed as current"
}

# An active pipeline whose run head is a descendant of the local tip (fix
# commits on the same history) remains current.
test_active_run_descendant_fix_head_remains_current() {
  reset_fakes
  local d base_head fix_head out
  d=$(new_case pipeline-descendant)
  make_repo_on_branch "$d/wt" cs/feat-pipeline
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'pipeline fix commit'
  fix_head=$(git -C "$d/wt" rev-parse HEAD)
  # Worktree still at the pre-fix tip; the row reports the pipeline fix head.
  git -C "$d/wt" reset -q --hard "$base_head"
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/pipe.meta" "pane=p-pipe" "workspace=w-pipe" "worktree=$d/wt" "kind=ship"
  CS_FAKE_RUN_LIST_JSON="$(run_list_json "$(run_row_json cs/feat-pipeline "$fix_head" running)")"
  out=$(run_crew_state "$d" pipe)
  assert_contains "$out" "source: run-step" "descendant pipeline fix head remains run-step"
  assert_contains "$out" "state: working" "active run remains working"
  pass "active run with valid descendant fix head remains current"
}

# Local work that advanced past the run's head invalidates the row.
test_local_advanced_past_run_head_invalidates() {
  reset_fakes
  local d run_head out
  d=$(new_case local-advanced)
  make_repo_on_branch "$d/wt" cs/feat-adv
  run_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'local stage-2 work after prior run'
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/adv.meta" "pane=p-adv" "workspace=w-adv" "worktree=$d/wt" "kind=ship"
  printf 'working: stage 2 implementation in progress\n' > "$d/state/adv.status"
  CS_FAKE_RUN_LIST_JSON="$(run_list_json "$(run_row_json cs/feat-adv "$run_head" awaiting_review)")"
  CS_FAKE_HERDR_BUSY=0
  out=$(run_crew_state "$d" adv)
  assert_not_contains "$out" "source: run-step" "local-advanced tip must not use the historical row"
  assert_contains "$out" "source: status-log" "falls back after local advanced past the run's head"
  assert_contains "$out" "state: working" "status-log working: is current"
  pass "local work advanced past the run's head invalidates attribution"
}

# --- pane process evidence: agent gone vs agent alive vs unreadable ----------

test_husk_pane_is_named_when_nothing_else_knows() {
  local d out
  reset_fakes
  d=$(new_case husk); make_repo_on_branch "$d/wt" cs/husk
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/husk.meta" "pane=p-husk" "workspace=w-husk" "worktree=$d/wt" "kind=ship"
  # No run, no boss-relevant log verb, pane readable but its agent exited.
  printf 'resolved: decision closed\n' > "$d/state/husk.status"
  CS_FAKE_HERDR_PROC=husk
  out=$(run_crew_state "$d" husk)
  assert_contains "$out" "source: pane-process" "a husk must be reported from process evidence"
  assert_contains "$out" "husk" "the detail must say the pane outlived its agent"
  pass "a pane that outlived its agent is named instead of reported as unknown with no source"
}

test_live_agent_process_is_not_a_husk() {
  local d out
  reset_fakes
  d=$(new_case not-husk); make_repo_on_branch "$d/wt" cs/nothusk
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/nothusk.meta" "pane=p-nothusk" "workspace=w-nothusk" "worktree=$d/wt" "kind=ship"
  printf 'resolved: decision closed\n' > "$d/state/nothusk.status"
  CS_FAKE_HERDR_PROC=agent
  out=$(run_crew_state "$d" nothusk)
  assert_not_contains "$out" "husk" "an agent that is still running must never be called a husk"
  pass "a pane with a live agent process is not a husk"
}

test_unreadable_process_table_fails_closed() {
  local d out
  reset_fakes
  d=$(new_case proc-unreadable); make_repo_on_branch "$d/wt" cs/procun
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/procun.meta" "pane=p-procun" "workspace=w-procun" "worktree=$d/wt" "kind=ship"
  printf 'resolved: decision closed\n' > "$d/state/procun.status"
  # process-info unavailable (old herdr, socket error, unsupported): "could not
  # read" must never be reported as "the agent is gone".
  out=$(run_crew_state "$d" procun)
  assert_not_contains "$out" "husk" "an unreadable process table must not be reported as a dead agent"
  assert_contains "$out" "source: none" "with no usable source the answer stays honestly unknown"
  pass "an unreadable process table fails closed instead of declaring the agent dead"
}

# Neither "TOON" nor "no-mistakes" belongs anywhere in this file any more:
# made's real run list --json fully replaced the TOON-format no-mistakes reader
# this script used to shell out to.
test_no_toon_or_no_mistakes_references_remain() {
  local src
  src=$(cat "$CREW_STATE")
  assert_not_contains "$src" 'TOON' "no TOON-format parsing may remain in cs-crew-state.sh"
  assert_not_contains "$src" 'no-mistakes' "no no-mistakes references may remain in cs-crew-state.sh"
  assert_contains "$src" "made's evidence store" \
    "doc comment must still cite made's evidence store as the evidence location"
  pass "cs-crew-state.sh is fully migrated off TOON/no-mistakes wording"
}

test_active_run_is_authoritative
test_active_run_queued_is_working
test_stale_needs_decision_superseded
test_stale_blocked_superseded
test_needs_review_superseded_once_run_exists
test_genuine_parked_not_superseded
test_terminal_completed
test_terminal_failed
test_terminal_failed_names_stage_without_error
test_failed_run_surfaces_plural_errors_array
test_awaiting_merge_reports_done_with_pr_url
test_canceled_reports_failed
test_superseded_reports_stale
test_ci_stage_pass_surfaces_done_without_a_log_line
test_ci_stage_pass_and_log_agree_stays_run_step_sourced
test_ci_stage_pending_ignores_a_stale_done_log
test_ci_stage_pending_stays_working_without_a_log
test_cross_branch_attribution_via_runs_list
test_cross_branch_attribution_picks_most_recent_row
test_other_branch_run_ignored
test_malformed_status_json_falls_back
test_no_run_busy_pane
test_no_run_unknown_agent_status_uses_pane_capture
test_no_run_idle_agent_status_corroborated_by_busy_pane
test_no_run_idle_agent_status_and_idle_pane_stays_idle
test_no_run_idle_pane_uses_log
test_no_run_idle_pane_needs_review_is_parked
test_needs_review_only_resolved_closes_key
test_no_run_idle_pane_uses_keyed_log
test_no_run_idle_pane_paused
test_no_run_idle_pane_custom_paused_verb
test_no_run_idle_capo_resolved_event_not_state
test_dead_pane_ignores_stale_status_log
test_dead_pane_still_reports_terminal_run_step
test_dead_pane_still_reports_active_run_step
test_no_timeout_uses_perl_bound
test_scout_skips_run_lookup
test_torn_down_worktree
test_missing_meta
test_provably_working_via_runs_list_fallback
test_not_provably_working_when_stopped
test_usage_error
test_historical_same_branch_rewritten_head_not_current
test_active_run_descendant_fix_head_remains_current
test_local_advanced_past_run_head_invalidates

test_husk_pane_is_named_when_nothing_else_knows
test_live_agent_process_is_not_a_husk
test_unreadable_process_table_fails_closed
test_no_toon_or_no_mistakes_references_remain

echo "all cs-crew-state tests passed"
