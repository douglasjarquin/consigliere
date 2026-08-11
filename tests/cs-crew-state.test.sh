#!/usr/bin/env bash
# Behavior tests for bin/cs-crew-state.sh - the deterministic soldier-current-
# state helper.
#
# The status file (state/<id>.status) is a best-effort append-only EVENT LOG, so
# `tail -1` of it reports the last event, not the current state. cs-crew-state
# reads the AUTHORITATIVE source (a matching no-mistakes run-step, else the
# pane busy-signature) and reconciles the possibly-stale log against it. These
# cases pin every branch of that logic, hermetically, over real throwaway git
# repos with a fake `no-mistakes` (run-step source) and a fake `herdr` (pane
# source):
#   (a) active run-step is authoritative                          -> run-step
#   (b) needs-decision/blocked log + resumed run = SUPERSEDED     -> run-step
#   (c) genuine parked run + needs-decision log = NOT superseded  -> run-step
#   (d) terminal run-step (passed/failed) is authoritative        -> run-step
#   (e) cross-branch attribution: this branch's own run found via list lookup
#   (f) no run + busy pane                                        -> pane
#   (g) no run + idle pane falls to the status-log verb           -> status-log
#   (h) dead pane: no run -> unknown/none; with a run -> run-step (not the shell)
#   (i) kind=scout skips the run lookup                           -> pane/status-log
#   (j) torn-down worktree / missing meta                         -> unknown/none
#   (k) crew_is_provably_working end-to-end over the REAL helper (not a canned
#       fake cs-crew-state.sh verdict): cross-branch attribution via the runs
#       list -> absorbed; genuinely no run anywhere + idle pane -> surfaced.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/cs-classify-lib.sh
. "$ROOT/bin/cs-classify-lib.sh"

command -v jq >/dev/null 2>&1 || fail "jq is required (cs-herdr-lib.sh parses herdr JSON with it)"

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
  # Real worktree HEAD for run head-binding (fixtures read CS_FAKE_RUN_HEAD).
  CS_FAKE_RUN_HEAD=$(git -C "$dir" rev-parse HEAD)
  export CS_FAKE_RUN_HEAD
}

# A fakebin with a fake `no-mistakes` (serves the env-driven run output) and a
# fake `herdr` (serves a live/dead pane, its rendered text, and the native
# agent status). The fake no-mistakes mirrors the real command surface the
# helper uses: `axi status`, `axi status --run <id>`, `axi logs`, and the
# top-level run-listing command `no-mistakes runs --limit N`, which is plain
# text - no run id, no quoting - serving CS_FAKE_RUNS_LIST verbatim. The fake
# herdr tolerates the trailing `--session <name>` cs_herdr always appends.
make_fakebin() {  # <dir> -> echoes fakebin path
  local dir=$1 fb
  fb=$(cs_fakebin "$dir")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status)
        shift
        if [ "${1:-}" = --run ]; then printf '%s\n' "${CS_FAKE_AXI_STATUS_RUN:-}"
        else printf '%s\n' "${CS_FAKE_AXI_STATUS:-}"; fi ;;
      logs)
        printf '%s\n' "${CS_FAKE_CI_LOGS:-}" ;;
    esac
    ;;
  runs)
    printf '%s\n' "${CS_FAKE_RUNS_LIST:-}" ;;
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
  chmod +x "$fb/no-mistakes" "$fb/herdr"
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
  CS_FAKE_AXI_STATUS=""
  CS_FAKE_AXI_STATUS_RUN=""
  CS_FAKE_RUNS_LIST=""
  CS_FAKE_HERDR_BUSY=0
  CS_FAKE_HERDR_MISSING=0
  CS_FAKE_HERDR_AGENT_STATUS=""
  CS_FAKE_HERDR_PROC=""
  CS_FAKE_CI_LOGS=""
  export CS_FAKE_AXI_STATUS CS_FAKE_AXI_STATUS_RUN CS_FAKE_RUNS_LIST
  export CS_FAKE_HERDR_BUSY CS_FAKE_HERDR_MISSING CS_FAKE_HERDR_AGENT_STATUS CS_FAKE_HERDR_PROC CS_FAKE_CI_LOGS
}

# --- run-object fixtures (TOON, as `no-mistakes axi status` emits) -----------

run_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${CS_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
EOF
}

run_fixing() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${CS_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
EOF
}

run_top_level_ci() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: ci
  head: "${CS_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
EOF
}

run_parked() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "${CS_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[2]{id,severity,file,line,action,description}:
    r1,warning,a.go,,auto-fix,ignored error
    r2,error,b.go,,ask-user,changes product behavior
gate: review
EOF
}

run_parked_scalar_gate_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${CS_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,ask-user,changes product behavior
gate: review
EOF
}

run_parked_in_gate_block() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${CS_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,ask-user,changes product behavior
gate:
  step: review
  status: fix_review
steps[3]{step,status,findings,duration_ms}:
  intent,completed,0,0
  review,fix_review,1,0
  test,pending,0,0
EOF
}

run_passed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${CS_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/1"
  findings: none
outcome: passed
EOF
}

run_failed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${CS_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
outcome: failed
EOF
}

run_ci_monitoring() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${CS_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
}

run_fixing_ci_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${CS_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
}

run_ci_fixing() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${CS_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,fixing,0,0
EOF
}

# ---------------------------------------------------------------------------
# (a) active run-step is authoritative
test_active_run_is_authoritative() {
  reset_fakes
  local d; d=$(new_case active)
  make_repo_on_branch "$d/wt" cs/feat-a
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-a.meta" "pane=p-feat-a" "workspace=w-feat-a" "worktree=$d/wt" "kind=ship"
  CS_FAKE_AXI_STATUS="$(run_running cs/feat-a)"
  local out; out=$(run_crew_state "$d" feat-a)
  assert_contains "$out" "state: working" "active run -> working"
  assert_contains "$out" "source: run-step" "active run -> run-step source"
  assert_contains "$out" "validating (running)" "active run reports the step"
  pass "active run-step is authoritative"
}

# (b) needs-decision log + a resumed (running/fixing) run = SUPERSEDED
test_stale_needs_decision_superseded() {
  reset_fakes
  local d; d=$(new_case superseded)
  make_repo_on_branch "$d/wt" cs/feat-b
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-b.meta" "pane=p-feat-b" "workspace=w-feat-b" "worktree=$d/wt" "kind=ship"
  printf 'working: started\nneeds-decision: pick A or B\n' > "$d/state/feat-b.status"
  CS_FAKE_AXI_STATUS="$(run_fixing cs/feat-b)"
  local out; out=$(run_crew_state "$d" feat-b)
  assert_contains "$out" "state: working" "resumed run -> working despite needs-decision log"
  assert_contains "$out" "source: run-step" "resumed run -> run-step source"
  assert_contains "$out" "superseded" "stale needs-decision log flagged superseded"
  pass "stale needs-decision over active run is superseded"
}

# blocked log + a resumed run is also superseded
test_stale_blocked_superseded() {
  reset_fakes
  local d; d=$(new_case superseded-blocked)
  make_repo_on_branch "$d/wt" cs/feat-bb
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-bb.meta" "pane=p-feat-bb" "workspace=w-feat-bb" "worktree=$d/wt" "kind=ship"
  printf 'blocked: waiting on review answer\n' > "$d/state/feat-bb.status"
  CS_FAKE_AXI_STATUS="$(run_running cs/feat-bb)"
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
  local d; d=$(new_case needs-review-run-exists)
  make_repo_on_branch "$d/wt" cs/feat-review-run
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-review-run.meta" "pane=p-feat-review-run" "workspace=w-feat-review-run" "worktree=$d/wt" "kind=ship"
  printf 'needs-review [key=pre-validation]: implementation committed\n' > "$d/state/feat-review-run.status"
  CS_FAKE_AXI_STATUS="$(run_parked cs/feat-review-run)"
  local out; out=$(run_crew_state "$d" feat-review-run)
  assert_contains "$out" "state: parked" "later parked run remains parked"
  assert_contains "$out" "source: run-step" "run existence is authoritative"
  assert_contains "$out" "superseded" "needs-review is superseded once any run exists"
  pass "needs-review is superseded once a validation run exists"
}

# (c) genuine parked run + needs-decision log AGREE -> parked, NOT superseded
test_genuine_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked)
  make_repo_on_branch "$d/wt" cs/feat-c
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-c.meta" "pane=p-feat-c" "workspace=w-feat-c" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-c.status"
  CS_FAKE_AXI_STATUS="$(run_parked cs/feat-c)"
  local out; out=$(run_crew_state "$d" feat-c)
  assert_contains "$out" "state: parked" "genuine parked run -> parked"
  assert_contains "$out" "source: run-step" "parked -> run-step source"
  assert_contains "$out" "2 finding(s)" "parked includes gate finding count"
  assert_contains "$out" "ask-user" "parked surfaces ask-user finding"
  assert_not_contains "$out" "superseded" "agreeing parked+needs-decision not flagged stale"
  pass "genuine parked run is not flagged superseded"
}

test_scalar_gate_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked-scalar-gate)
  make_repo_on_branch "$d/wt" cs/feat-cs
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-cs.meta" "pane=p-feat-cs" "workspace=w-feat-cs" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-cs.status"
  CS_FAKE_AXI_STATUS="$(run_parked_scalar_gate_running cs/feat-cs)"
  local out; out=$(run_crew_state "$d" feat-cs)
  assert_contains "$out" "state: parked" "scalar gate wait -> parked"
  assert_contains "$out" "source: run-step" "scalar gate wait -> run-step source"
  assert_contains "$out" "parked at review" "scalar gate wait names the gate"
  assert_contains "$out" "1 finding(s)" "scalar gate wait includes finding count"
  assert_not_contains "$out" "superseded" "scalar gate wait not flagged stale"
  pass "scalar gate parked run is not flagged superseded"
}

test_gate_block_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked-gate-block)
  make_repo_on_branch "$d/wt" cs/feat-cb
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-cb.meta" "pane=p-feat-cb" "workspace=w-feat-cb" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-cb.status"
  CS_FAKE_AXI_STATUS="$(run_parked_in_gate_block cs/feat-cb)"
  local out; out=$(run_crew_state "$d" feat-cb)
  assert_contains "$out" "state: parked" "gate block wait -> parked"
  assert_contains "$out" "source: run-step" "gate block wait -> run-step source"
  assert_contains "$out" "parked at review" "gate block wait names the gate"
  assert_contains "$out" "1 finding(s)" "gate block wait includes finding count"
  assert_not_contains "$out" "superseded" "gate block wait not flagged stale"
  pass "gate block parked run is not flagged superseded"
}

test_ci_ready_done_log_beats_monitoring_run() {
  reset_fakes
  local d; d=$(new_case ci-ready)
  make_repo_on_branch "$d/wt" cs/feat-ci
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-ci.meta" "pane=p-feat-ci" "workspace=w-feat-ci" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-ci.status"
  CS_FAKE_AXI_STATUS="$(run_ci_monitoring cs/feat-ci)"
  local out; out=$(run_crew_state "$d" feat-ci)
  assert_contains "$out" "state: done" "ci-ready status log -> done"
  assert_contains "$out" "source: status-log" "ci-ready state comes from the status log"
  assert_contains "$out" "checks green" "ci-ready detail preserves the report"
  assert_not_contains "$out" "state: working" "ci-ready is not hidden by monitoring run"
  pass "ci-ready status log beats monitoring run"
}

# Regression for the PR #252 incident: the soldier's own status log never got a
# "done: ... checks green" line (log_reports_ci_ready above does not apply),
# but the ci step's log tail shows CI is actually green and only waiting on
# merge/close. cs-crew-state must surface this as done, not "validating
# (running)", so a green PR is never silently absorbed as still-in-progress.
test_ci_monitoring_checks_green_surfaces_done() {
  reset_fakes
  local d; d=$(new_case ci-green)
  make_repo_on_branch "$d/wt" cs/feat-cigreen
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-cigreen.meta" "pane=p-feat-cigreen" "workspace=w-feat-cigreen" "worktree=$d/wt" "kind=ship"
  # No status-log line at all: the soldier never reported its own checks-green line.
  CS_FAKE_AXI_STATUS="$(run_ci_monitoring cs/feat-cigreen)"
  CS_FAKE_CI_LOGS=$(cat <<'EOF'
CI checks running, waiting for results...
all CI checks passed - still monitoring until merged or closed
EOF
)
  local out; out=$(run_crew_state "$d" feat-cigreen)
  assert_contains "$out" "state: done" "green ci-monitor run -> done"
  assert_contains "$out" "source: run-step" "green ci-monitor -> run-step source"
  assert_contains "$out" "checks green" "green ci-monitor detail mentions checks green"
  assert_not_contains "$out" "state: working" "green ci-monitor must not read as still validating"
  pass "ci-monitoring run with checks already green surfaces done"
}

test_top_level_ci_checks_green_surfaces_done() {
  reset_fakes
  local d; d=$(new_case top-level-ci-green)
  make_repo_on_branch "$d/wt" cs/feat-topcigreen
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-topcigreen.meta" "pane=p-feat-topcigreen" "workspace=w-feat-topcigreen" "worktree=$d/wt" "kind=ship"
  CS_FAKE_AXI_STATUS="$(run_top_level_ci cs/feat-topcigreen)"
  CS_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topcigreen)
  assert_contains "$out" "state: done" "top-level ci with green log -> done"
  assert_contains "$out" "source: run-step" "top-level ci green -> run-step source"
  assert_contains "$out" "checks green" "top-level ci green detail mentions checks green"
  assert_not_contains "$out" "state: working" "top-level ci green must not stay working"
  pass "top-level ci status uses ci log green marker"
}

test_ci_monitoring_no_checks_terminal_surfaces_done() {
  reset_fakes
  local d; d=$(new_case ci-nochecks)
  make_repo_on_branch "$d/wt" cs/feat-cinochecks
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-cinochecks.meta" "pane=p-feat-cinochecks" "workspace=w-feat-cinochecks" "worktree=$d/wt" "kind=ship"
  CS_FAKE_AXI_STATUS="$(run_ci_monitoring cs/feat-cinochecks)"
  CS_FAKE_CI_LOGS="no CI checks reported - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-cinochecks)
  assert_contains "$out" "state: done" "terminal no-checks ci-monitor run -> done"
  assert_contains "$out" "checks green" "terminal no-checks ci-monitor detail mentions checks green"
  pass "terminal no-checks ci-monitor marker surfaces done"
}

test_ci_monitoring_green_then_rearm_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-then-rearm)
  make_repo_on_branch "$d/wt" cs/feat-cirearm
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-cirearm.meta" "pane=p-feat-cirearm" "workspace=w-feat-cirearm" "worktree=$d/wt" "kind=ship"
  CS_FAKE_AXI_STATUS="$(run_ci_monitoring cs/feat-cirearm)"
  CS_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
EOF
)
  local out; out=$(run_crew_state "$d" feat-cirearm)
  assert_contains "$out" "state: working" "base-advance rearm marker -> working"
  assert_not_contains "$out" "state: done" "base-advance rearm marker must not read as done"
  assert_not_contains "$out" "checks green" "base-advance rearm marker must not read as checks green"
  pass "base-advance rearm after green stays working"
}

test_ci_monitoring_no_checks_yet_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-nochecks-yet)
  make_repo_on_branch "$d/wt" cs/feat-cinochecksyet
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-cinochecksyet.meta" "pane=p-feat-cinochecksyet" "workspace=w-feat-cinochecksyet" "worktree=$d/wt" "kind=ship"
  CS_FAKE_AXI_STATUS="$(run_ci_monitoring cs/feat-cinochecksyet)"
  CS_FAKE_CI_LOGS=$(cat <<'EOF'
no CI checks reported - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
no CI checks reported yet, waiting for checks to register...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cinochecksyet)
  assert_contains "$out" "state: working" "pending no-checks marker -> working"
  assert_not_contains "$out" "state: done" "pending no-checks marker must not read as done"
  assert_not_contains "$out" "checks green" "pending no-checks marker must not read as checks green"
  pass "pending no-checks ci-monitor marker stays working"
}

test_ci_monitoring_still_waiting_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-waiting)
  make_repo_on_branch "$d/wt" cs/feat-ciwait
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-ciwait.meta" "pane=p-feat-ciwait" "workspace=w-feat-ciwait" "worktree=$d/wt" "kind=ship"
  CS_FAKE_AXI_STATUS="$(run_ci_monitoring cs/feat-ciwait)"
  CS_FAKE_CI_LOGS="CI checks running, waiting for results..."
  local out; out=$(run_crew_state "$d" feat-ciwait)
  assert_contains "$out" "state: working" "ci step still red -> working"
  assert_not_contains "$out" "checks green" "no green marker present -> no checks-green detail"
  pass "ci-monitoring run with checks not yet green stays working"
}

# A later merge-conflict auto-fix round after an earlier green reading must
# not be masked: the MOST RECENT marker in the log tail wins.
test_ci_monitoring_green_then_new_issue_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-then-issue)
  make_repo_on_branch "$d/wt" cs/feat-cirelapse
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-cirelapse.meta" "pane=p-feat-cirelapse" "workspace=w-feat-cirelapse" "worktree=$d/wt" "kind=ship"
  CS_FAKE_AXI_STATUS="$(run_ci_monitoring cs/feat-cirelapse)"
  CS_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
issues detected: merge conflict - auto-fixing (attempt 2/10)...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cirelapse)
  assert_contains "$out" "state: working" "a later relapse marker must win over an earlier green one"
  assert_not_contains "$out" "state: done" "relapsed ci run must not read as done"
  pass "a fresh issue after an earlier green reading is not masked"
}

test_ci_ready_done_log_relapse_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-ready-then-relapse)
  make_repo_on_branch "$d/wt" cs/feat-cireadyrelapse
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-cireadyrelapse.meta" "pane=p-feat-cireadyrelapse" "workspace=w-feat-cireadyrelapse" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cireadyrelapse.status"
  CS_FAKE_AXI_STATUS="$(run_ci_monitoring cs/feat-cireadyrelapse)"
  CS_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
CI checks running, waiting for results...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cireadyrelapse)
  assert_contains "$out" "state: working" "a stale ready status must not mask a later CI relapse"
  assert_contains "$out" "source: run-step" "relapsed ci run remains run-step sourced"
  assert_not_contains "$out" "state: done" "relapsed ci run with stale done log must not read as done"
  pass "stale checks-green status log does not mask CI relapse"
}

test_ci_fixing_after_green_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-fixing-after-green)
  make_repo_on_branch "$d/wt" cs/feat-cifixing
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-cifixing.meta" "pane=p-feat-cifixing" "workspace=w-feat-cifixing" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cifixing.status"
  CS_FAKE_AXI_STATUS="$(run_ci_fixing cs/feat-cifixing)"
  CS_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-cifixing)
  assert_contains "$out" "state: working" "ci fixing step must stay working"
  assert_contains "$out" "source: run-step" "ci fixing remains run-step sourced"
  assert_not_contains "$out" "state: done" "ci fixing must not read as checks-green done"
  pass "ci fixing is not overridden by an earlier green marker"
}

test_top_level_fixing_ci_running_after_green_stays_working() {
  reset_fakes
  local d; d=$(new_case top-level-fixing-ci-running)
  make_repo_on_branch "$d/wt" cs/feat-topfixingci
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-topfixingci.meta" "pane=p-feat-topfixingci" "workspace=w-feat-topfixingci" "worktree=$d/wt" "kind=ship"
  CS_FAKE_AXI_STATUS="$(run_fixing_ci_running cs/feat-topfixingci)"
  CS_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topfixingci)
  assert_contains "$out" "state: working" "top-level fixing with ci running must stay working"
  assert_contains "$out" "source: run-step" "top-level fixing with ci running remains run-step sourced"
  assert_contains "$out" "validating (fixing)" "top-level fixing keeps fixing detail"
  assert_not_contains "$out" "state: done" "top-level fixing must not use stale green marker"
  pass "top-level fixing is not overridden by a stale ci running row"
}

test_top_level_fixing_done_log_stays_working() {
  reset_fakes
  local d; d=$(new_case top-level-fixing-done-log)
  make_repo_on_branch "$d/wt" cs/feat-topfixing
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-topfixing.meta" "pane=p-feat-topfixing" "workspace=w-feat-topfixing" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-topfixing.status"
  CS_FAKE_AXI_STATUS="$(run_fixing cs/feat-topfixing)"
  CS_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topfixing)
  assert_contains "$out" "state: working" "top-level fixing must stay working"
  assert_contains "$out" "source: run-step" "top-level fixing remains run-step sourced"
  assert_contains "$out" "validating (fixing)" "top-level fixing keeps fixing detail"
  assert_not_contains "$out" "state: done" "top-level fixing must not read as stale checks-green done"
  pass "top-level fixing is not overridden by a stale done log"
}

# (d) terminal run-step is authoritative
test_terminal_passed() {
  reset_fakes
  local d; d=$(new_case passed)
  make_repo_on_branch "$d/wt" cs/feat-d
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-d.meta" "pane=p-feat-d" "workspace=w-feat-d" "worktree=$d/wt" "kind=ship"
  CS_FAKE_AXI_STATUS="$(run_passed cs/feat-d)"
  local out; out=$(run_crew_state "$d" feat-d)
  assert_contains "$out" "state: done" "passed run -> done"
  assert_contains "$out" "source: run-step" "passed -> run-step source"
  pass "terminal passed run is authoritative"
}

test_terminal_failed() {
  reset_fakes
  local d; d=$(new_case failed)
  make_repo_on_branch "$d/wt" cs/feat-e
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-e.meta" "pane=p-feat-e" "workspace=w-feat-e" "worktree=$d/wt" "kind=ship"
  CS_FAKE_AXI_STATUS="$(run_failed cs/feat-e)"
  local out; out=$(run_crew_state "$d" feat-e)
  assert_contains "$out" "state: failed" "failed run -> failed"
  assert_contains "$out" "source: run-step" "failed -> run-step source"
  pass "terminal failed run is authoritative"
}

# (e) cross-branch attribution: `axi status` returns ANOTHER branch's run (the
# routine case once more than one soldier validates the same underlying repo
# concurrently - they share ONE no-mistakes repo registration), so the helper
# falls back to the real top-level `no-mistakes runs` listing to learn whether
# THIS branch has an active run of its own.
test_cross_branch_attribution_via_runs_list() {
  reset_fakes
  local d short; d=$(new_case crossbranch)
  make_repo_on_branch "$d/wt" cs/feat-f
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-f.meta" "pane=p-feat-f" "workspace=w-feat-f" "worktree=$d/wt" "kind=ship"
  # The repo-wide active/most-recent run belongs to a different soldier's branch.
  CS_FAKE_AXI_STATUS="$(run_running cs/other-soldier)"
  # Real `no-mistakes runs` shape: plain text, newest-first, no run id, no
  # quoting - "<status> <branch> <short-sha> <date> [<pr-url>]".
  CS_FAKE_RUNS_LIST="$(cat <<EOF
  running    cs/other-soldier aaaaaaa  2026-07-02 22:10
  running    cs/feat-f ${short}  2026-07-02 22:05
EOF
)"
  local out; out=$(run_crew_state "$d" feat-f)
  assert_contains "$out" "state: working" "this branch's own run attributed via the runs list"
  assert_contains "$out" "source: run-step" "runs-list-resolved run -> run-step source"
  pass "cross-branch run is attributed via the real runs list"
}

# The runs list is newest-first; a branch with an OLDER completed run must not
# shadow its own newer active one - the first (topmost) matching row wins.
test_cross_branch_attribution_picks_most_recent_row() {
  reset_fakes
  local d short; d=$(new_case crossbranch-mostrecent)
  make_repo_on_branch "$d/wt" cs/feat-fq
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-fq.meta" "pane=p-feat-fq" "workspace=w-feat-fq" "worktree=$d/wt" "kind=ship"
  CS_FAKE_AXI_STATUS="$(run_running cs/other-soldier)"
  CS_FAKE_RUNS_LIST="$(cat <<EOF
  running    cs/other-soldier aaaaaaa  2026-07-02 22:10
  running    cs/feat-fq ${short}  2026-07-02 21:50
  completed  cs/feat-fq bbbbbbb  2026-07-02 20:00  https://github.com/o/r/pull/1
EOF
)"
  local out; out=$(run_crew_state "$d" feat-fq)
  assert_contains "$out" "state: working" "most recent (running) row wins over an older completed row"
  assert_contains "$out" "source: run-step" "most-recent-row resolution -> run-step source"
  pass "cross-branch attribution picks the branch's most recent row"
}

test_coarse_run_does_not_probe_other_branch_ci_log_for_ready_status() {
  reset_fakes
  local d short; d=$(new_case coarse-ready-other-log)
  make_repo_on_branch "$d/wt" cs/feat-coarseready
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-coarseready.meta" "pane=p-feat-coarseready" "workspace=w-feat-coarseready" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/4 checks green\n' > "$d/state/feat-coarseready.status"
  CS_FAKE_AXI_STATUS="$(run_ci_monitoring cs/other-soldier)"
  CS_FAKE_RUNS_LIST="$(cat <<EOF
  running    cs/other-soldier aaaaaaa  2026-07-02 22:10
  running    cs/feat-coarseready ${short}  2026-07-02 22:05
EOF
)"
  CS_FAKE_CI_LOGS="CI checks running, waiting for results..."
  local out; out=$(run_crew_state "$d" feat-coarseready)
  assert_contains "$out" "state: done" "coarse ready status -> done"
  assert_contains "$out" "source: status-log" "coarse ready status remains status-log sourced"
  assert_not_contains "$out" "state: working" "coarse ready status must not be suppressed by another branch log"
  pass "coarse run does not probe another branch's ci log"
}

# A different-branch run with NO matching runs-list row must NOT be
# misattributed, and must not be treated as a false "working" verdict either.
test_other_branch_run_ignored() {
  reset_fakes
  local d; d=$(new_case otherbranch)
  make_repo_on_branch "$d/wt" cs/feat-g
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-g.meta" "pane=p-feat-g" "workspace=w-feat-g" "worktree=$d/wt" "kind=ship"
  printf 'done: implemented, ready to validate\n' > "$d/state/feat-g.status"
  CS_FAKE_AXI_STATUS="$(run_running cs/some-other)"
  CS_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    cs/some-other aaaaaaa  2026-07-02 22:10
EOF
)"
  CS_FAKE_HERDR_BUSY=0
  local out; out=$(run_crew_state "$d" feat-g)
  assert_not_contains "$out" "source: run-step" "another branch's run not misattributed"
  assert_contains "$out" "source: status-log" "no own run -> falls back to status-log"
  assert_contains "$out" "state: done" "falls back to the log verb"
  pass "another branch's run is ignored, falls back"
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
  CS_FAKE_AXI_STATUS=""
  CS_FAKE_RUNS_LIST=""
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
  CS_FAKE_AXI_STATUS=""
  CS_FAKE_RUNS_LIST=""
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
# `no-mistakes axi run` (no --yes; blocks until a gate or outcome) is not
# generating for that whole span, so agent.get can read idle while the pane's
# own rendered text still shows the busy banner for the entire call. `idle`
# must be corroborated with that text exactly like `unknown` is, not trusted
# outright (cs_herdr_agent_busy_state owns this policy).
test_no_run_idle_agent_status_corroborated_by_busy_pane() {
  reset_fakes
  local d; d=$(new_case herdr-idle-busy-pane)
  make_repo_on_branch "$d/wt" cs/feat-herdr-idle
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-herdr-idle.meta" "pane=p-feat-herdr-idle" "workspace=w-feat-herdr-idle" "worktree=$d/wt" "kind=ship"
  # No run attributable: the pane fallback is the only remaining signal.
  CS_FAKE_AXI_STATUS=""
  CS_FAKE_RUNS_LIST=""
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
  CS_FAKE_AXI_STATUS=""
  CS_FAKE_RUNS_LIST=""
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
  CS_FAKE_AXI_STATUS=""
  CS_FAKE_HERDR_BUSY=0
  local out; out=$(run_crew_state "$d" feat-i)
  assert_contains "$out" "state: parked" "needs-decision log -> parked"
  assert_contains "$out" "source: status-log" "idle pane -> status-log source"
  pass "no run + idle pane uses the status-log verb"
}

# (g'') a no-mistakes soldier that committed and is waiting for consigliere to
# review it reports needs-review, which must read as PARKED, never done. This is
# the whole point of the verb: `done:` at the commit was indistinguishable from
# `done: PR ... checks green`, so a missed review looked like finished work and
# idled niceuptime-590 for 56m on 2026-08-02.
test_no_run_idle_pane_needs_review_is_parked() {
  reset_fakes
  local d; d=$(new_case needs-review)
  make_repo_on_branch "$d/wt" cs/feat-review
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-review.meta" "pane=p-feat-review" "workspace=w-feat-review" "worktree=$d/wt" "kind=ship"
  printf 'needs-review: retired the legacy flag; awaiting review before validation\n' > "$d/state/feat-review.status"
  CS_FAKE_AXI_STATUS=""
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
  CS_FAKE_AXI_STATUS=""
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
  CS_FAKE_AXI_STATUS=""
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
  CS_FAKE_AXI_STATUS=""
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
  CS_FAKE_AXI_STATUS=""
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
  CS_FAKE_AXI_STATUS=""
  CS_FAKE_RUNS_LIST=""
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
  local d; d=$(new_case dead-pane-done)
  make_repo_on_branch "$d/wt" cs/feat-dead-done
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-dead-done.meta" "pane=p-feat-dead-done" "workspace=w-feat-dead-done" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/3 checks green\n' > "$d/state/feat-dead-done.status"
  CS_FAKE_AXI_STATUS="$(run_passed cs/feat-dead-done)"
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
  local d; d=$(new_case dead-pane-active)
  make_repo_on_branch "$d/wt" cs/feat-dead-act
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-dead-act.meta" "pane=p-feat-dead-act" "workspace=w-feat-dead-act" "worktree=$d/wt" "kind=ship"
  CS_FAKE_AXI_STATUS="$(run_running cs/feat-dead-act)"
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
  calls_file="$d/no-mistakes.calls"
  : > "$calls_file"
  cat > "$d/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CS_FAKE_NM_CALLS:-/dev/null}"
while :; do :; done
SH
  chmod +x "$d/fakebin/no-mistakes"
  toolbin=$(make_no_timeout_toolbin "$d")
  cs_write_meta "$d/state/feat-timeout.meta" "pane=p-feat-timeout" "workspace=w-feat-timeout" "worktree=$d/wt" "kind=ship"
  CS_FAKE_HERDR_AGENT_STATUS=working
  start=$SECONDS
  out=$(CS_FAKE_NM_CALLS="$calls_file" PATH="$d/fakebin:$toolbin" CS_STATE_OVERRIDE="$d/state" CS_CREW_STATE_NM_TIMEOUT=1 "$CREW_STATE" feat-timeout)
  elapsed=$((SECONDS - start))
  assert_contains "$out" "state: working" "timed-out no-mistakes falls back to pane"
  assert_contains "$out" "source: pane" "timed-out no-mistakes -> pane source"
  [ "$elapsed" -lt 5 ] || fail "perl timeout did not bound no-mistakes calls (elapsed ${elapsed}s)"
  calls=$(awk 'END { print NR + 0 }' "$calls_file" 2>/dev/null || echo 0)
  # The property is that a bounded lookup returning nothing is not RETRIED, so
  # the ceiling is what matters. Zero is a legitimate outcome of the same bound:
  # cs_run_timed forks, then alarms after the 1s this case configures, and on a
  # loaded host that alarm can fire before the forked child has finished exec'ing
  # the fake, which records its call from inside the exec'd script. Asserting
  # exactly one made this case fail intermittently under a full suite run.
  [ "$calls" -le 1 ] || fail "empty no-mistakes status triggered extra lookups ($calls calls)"
  pass "no timeout command uses perl bound"
}

# (i) kind=scout skips the run lookup entirely (its deliverable is a report).
test_scout_skips_run_lookup() {
  reset_fakes
  local d; d=$(new_case scout)
  make_repo_on_branch "$d/wt" cs/scout-j
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/scout-j.meta" "pane=p-scout-j" "workspace=w-scout-j" "worktree=$d/wt" "kind=scout"
  # Even if a run existed on this branch, a scout must not read it.
  CS_FAKE_AXI_STATUS="$(run_running cs/scout-j)"
  CS_FAKE_HERDR_AGENT_STATUS=working
  local out; out=$(run_crew_state "$d" scout-j)
  assert_not_contains "$out" "source: run-step" "scout ignores no-mistakes run-step"
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
# canned fake verdict): a validating soldier whose bare `axi status` answer
# belongs to another branch must still be absorbed by the watcher via the
# runs-list fallback (working), while a soldier with genuinely no run anywhere
# and an idle pane must still surface (the safety property the fallback must
# never widen away).
test_provably_working_via_runs_list_fallback() {
  reset_fakes
  local d short; d=$(new_case provably-working-crossbranch)
  make_repo_on_branch "$d/wt" cs/feat-provable
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-provable.meta" "pane=p-feat-provable" "workspace=w-feat-provable" "worktree=$d/wt" "kind=ship"
  CS_FAKE_AXI_STATUS="$(run_running cs/other-soldier)"
  CS_FAKE_RUNS_LIST="$(cat <<EOF
  running    cs/other-soldier aaaaaaa  2026-07-02 22:10
  running    cs/feat-provable ${short}  2026-07-02 22:05
EOF
)"
  PATH="$d/fakebin:$PATH" CS_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-provable \
    || fail "cross-branch attribution via the runs list was not treated as provably working"
  pass "crew_is_provably_working absorbs a validating soldier found only via the runs-list fallback"
}

test_not_provably_working_when_stopped() {
  reset_fakes
  local d; d=$(new_case provably-working-stopped)
  make_repo_on_branch "$d/wt" cs/feat-stopped
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/feat-stopped.meta" "pane=p-feat-stopped" "workspace=w-feat-stopped" "worktree=$d/wt" "kind=ship"
  # Repo-wide run belongs to someone else, and this branch has no row in the
  # runs list either (it never validated, or genuinely finished/stopped) - the
  # only remaining signal is the pane, which is idle.
  CS_FAKE_AXI_STATUS="$(run_running cs/other-soldier)"
  CS_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    cs/other-soldier aaaaaaa  2026-07-02 22:10
EOF
)"
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

# Head-binding: same branch name with a rewritten/diverged worktree tip must not
# attribute a historical no-mistakes run (multi-stage branch reuse incident).
test_historical_same_branch_rewritten_head_not_current() {
  reset_fakes
  local d old_head new_head out
  d=$(new_case rewritten-head)
  make_repo_on_branch "$d/wt" cs/todo-flag
  old_head=$(git -C "$d/wt" rev-parse HEAD)
  # Simulate a rebase rewrite: orphan new history on the same branch name.
  git -C "$d/wt" checkout -q --orphan tmp-rewrite
  git -C "$d/wt" commit -q --allow-empty -m 'rewritten tip'
  git -C "$d/wt" branch -q -M cs/todo-flag
  new_head=$(git -C "$d/wt" rev-parse HEAD)
  [ "$old_head" != "$new_head" ] || fail "rewrite did not produce a new head"
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/wishlist.meta" "pane=p-wishlist" "workspace=w-wishlist" "worktree=$d/wt" "kind=ship"
  printf 'working: stage 2 setup complete rebased onto merged #76\n' > "$d/state/wishlist.status"
  # Historical run still reports the pre-rewrite head on the reused branch.
  CS_FAKE_RUN_HEAD="$old_head"
  CS_FAKE_AXI_STATUS="$(run_parked cs/todo-flag)"
  CS_FAKE_HERDR_BUSY=0
  out=$(run_crew_state "$d" wishlist)
  assert_not_contains "$out" "source: run-step" "historical rewritten head must not use run-step"
  assert_not_contains "$out" "parked at" "historical parked run must not mask current state"
  assert_contains "$out" "source: status-log" "falls back to status-log after head mismatch"
  assert_contains "$out" "state: working" "status-log working: remains current"
  pass "historical same-branch rewritten head is not attributed as current"
}

# Head-binding: an active pipeline whose run head is a descendant of the local
# tip (fix commits on the same history) remains current.
test_active_run_descendant_fix_head_remains_current() {
  reset_fakes
  local d base_head fix_head out
  d=$(new_case pipeline-descendant)
  make_repo_on_branch "$d/wt" cs/feat-pipeline
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'pipeline fix commit'
  fix_head=$(git -C "$d/wt" rev-parse HEAD)
  # Worktree still at the pre-fix tip; run reports the pipeline fix head.
  git -C "$d/wt" reset -q --hard "$base_head"
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/pipe.meta" "pane=p-pipe" "workspace=w-pipe" "worktree=$d/wt" "kind=ship"
  CS_FAKE_RUN_HEAD="$fix_head"
  CS_FAKE_AXI_STATUS="$(run_fixing cs/feat-pipeline)"
  out=$(run_crew_state "$d" pipe)
  assert_contains "$out" "source: run-step" "descendant pipeline fix head remains run-step"
  assert_contains "$out" "state: working" "active fixing run remains working"
  pass "active run with valid descendant fix head remains current"
}

# Head-binding: local work that advanced past the run head invalidates the run.
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
  CS_FAKE_RUN_HEAD="$run_head"
  CS_FAKE_AXI_STATUS="$(run_parked cs/feat-adv)"
  CS_FAKE_HERDR_BUSY=0
  out=$(run_crew_state "$d" adv)
  assert_not_contains "$out" "source: run-step" "local-advanced tip must not use historical run"
  assert_contains "$out" "source: status-log" "falls back after local advanced past run"
  assert_contains "$out" "state: working" "status-log working: is current"
  pass "local work advanced past run head invalidates attribution"
}

test_missing_run_head_falls_back_to_current_state() {
  reset_fakes
  local d out
  d=$(new_case missing-run-head)
  make_repo_on_branch "$d/wt" cs/feat-no-head
  make_fakebin "$d" >/dev/null
  cs_write_meta "$d/state/no-head.meta" "pane=p-no-head" "workspace=w-no-head" "worktree=$d/wt" "kind=ship"
  printf 'working: current stage still in progress\n' > "$d/state/no-head.status"
  CS_FAKE_AXI_STATUS=$(run_parked cs/feat-no-head | grep -v '^  head:')
  CS_FAKE_RUNS_LIST=""
  CS_FAKE_HERDR_BUSY=0
  out=$(run_crew_state "$d" no-head)
  assert_not_contains "$out" "source: run-step" "missing run head must not permit branch-only attribution"
  assert_contains "$out" "source: status-log" "missing run head falls back to current state sources"
  assert_contains "$out" "state: working" "status-log remains current after missing run head"
  pass "missing run head falls back instead of matching by branch"
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

test_active_run_is_authoritative
test_stale_needs_decision_superseded
test_stale_blocked_superseded
test_needs_review_superseded_once_run_exists
test_genuine_parked_not_superseded
test_scalar_gate_parked_not_superseded
test_gate_block_parked_not_superseded
test_ci_ready_done_log_beats_monitoring_run
test_ci_monitoring_checks_green_surfaces_done
test_top_level_ci_checks_green_surfaces_done
test_ci_monitoring_no_checks_terminal_surfaces_done
test_ci_monitoring_green_then_rearm_stays_working
test_ci_monitoring_no_checks_yet_stays_working
test_ci_monitoring_still_waiting_stays_working
test_ci_monitoring_green_then_new_issue_stays_working
test_ci_ready_done_log_relapse_stays_working
test_ci_fixing_after_green_stays_working
test_top_level_fixing_ci_running_after_green_stays_working
test_top_level_fixing_done_log_stays_working
test_terminal_passed
test_terminal_failed
test_cross_branch_attribution_via_runs_list
test_cross_branch_attribution_picks_most_recent_row
test_coarse_run_does_not_probe_other_branch_ci_log_for_ready_status
test_other_branch_run_ignored
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
test_missing_run_head_falls_back_to_current_state

test_husk_pane_is_named_when_nothing_else_knows
test_live_agent_process_is_not_a_husk
test_unreadable_process_table_fails_closed

echo "all cs-crew-state tests passed"
