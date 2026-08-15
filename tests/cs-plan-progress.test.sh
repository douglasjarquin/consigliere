#!/usr/bin/env bash
# Behavior: plan-first brief scaffolding arms a read-only, hash-bound state
# check that reports changed Boulder plan checkbox progress without touching the
# plan or reading Herdr workspace metadata.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(cs_test_tmproot cs-plan-progress)
BRIEF="$ROOT/bin/cs-brief.sh"

export CODEX_HOME="$TMP_ROOT/codex-home"
mkdir -p "$CODEX_HOME/plugins/cache/sisyphuslabs/omo"

new_case() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/data" "$dir/state" "$dir/worktree/.omo/plans"
  printf '%s\n' "$dir"
}

write_meta() {
  local state=$1 id=$2 worktree=$3
  cs_write_meta "$state/$id.meta" \
    "workspace=not-used" "pane=not-used" "kind=ship" "mode=local-only" \
    "yolo=off" "worktree=$worktree" "project=fixture"
}

write_boulder() {
  local worktree=$1 plan=$2 status=${3:-active}
  cat > "$worktree/.omo/boulder.json" <<EOF
{
  "schema_version": 2,
  "active_work_id": "work_1",
  "works": {
    "work_1": {
      "work_id": "work_1",
      "active_plan": "$plan",
      "plan_name": "fixture-plan",
      "session_ids": ["codex:not-consigliere"],
      "status": "$status",
      "worktree_path": null
    }
  }
}
EOF
}

run_brief() {
  local dir=$1 id=$2
  CS_DATA_OVERRIDE="$dir/data" CS_STATE_OVERRIDE="$dir/state" \
    "$BRIEF" "$id" fixture --mode local-only --exec-mode plan-first >/dev/null
}

run_check() {
  local dir=$1 id=$2
  CS_STATE_OVERRIDE="$dir/state" "$dir/state/$id.check.sh"
}

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

file_mode() {
  if [ "$(uname -s)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

test_happy_path_reports_changed_progress_and_preserves_plan() {
  local dir state worktree plan before after out
  dir=$(new_case happy)
  state="$dir/state"
  worktree="$dir/worktree"
  plan="$worktree/.omo/plans/fixture.md"
  cat > "$plan" <<'EOF'
# Fixture plan

## TODOs
- [ ] 1. first task
- [x] 2. second task

## Final Verification Wave
- [ ] F1. final check
EOF
  write_boulder "$worktree" '.omo/plans/fixture.md'
  run_brief "$dir" plan
  write_meta "$state" plan "$worktree"

  assert_present "$state/plan.check.sh" "plan-first brief must arm the progress check"
  [ "$(file_mode "$state/plan.check.sh")" = 700 ] \
    || fail "progress check must be mode 0700"
  assert_present "$state/plan.check-trust" "plan progress check must have a trust binding"

  before=$(sha256 "$plan")
  out=$(run_check "$dir" plan)
  after=$(sha256 "$plan")
  [ "$out" = 'plan progress: remaining=2 total=3' ] \
    || fail "happy-path progress was not reported exactly: $out"
  [ "$before" = "$after" ] || fail "the progress check mutated the plan"

  out=$(run_check "$dir" plan)
  [ -z "$out" ] || fail "unchanged progress must stay silent: $out"

  printf '%s\n' '# progress update' '- [x] 1. first task' > "$plan"
  printf '%s\n' '- [x] 2. second task' '- [ ] F1. final check' >> "$plan"
  before=$(sha256 "$plan")
  out=$(run_check "$dir" plan)
  after=$(sha256 "$plan")
  [ "$out" = 'plan progress: remaining=1 total=3' ] \
    || fail "changed progress was not reported exactly: $out"
  [ "$before" = "$after" ] || fail "the changed-progress check mutated the plan"
  pass "plan-first progress reports changed remaining/total and preserves plan bytes"
}

test_edge_cases_are_silent_or_report_completed_plan() {
  local dir state worktree plan before after out

  dir=$(new_case empty)
  state="$dir/state"; worktree="$dir/worktree"; plan="$worktree/.omo/plans/empty.md"
  : > "$plan"
  write_boulder "$worktree" '.omo/plans/empty.md'
  run_brief "$dir" empty
  write_meta "$state" empty "$worktree"
  out=$(run_check "$dir" empty)
  [ -z "$out" ] || fail "an empty plan must stay silent: $out"
  assert_absent "$worktree/.omo/plans/empty.md.progress" "empty-plan probe wrote beside the plan"
  pass "empty plan stays silent"

  dir=$(new_case malformed)
  state="$dir/state"; worktree="$dir/worktree"
  printf '{not-json\n' > "$worktree/.omo/boulder.json"
  run_brief "$dir" malformed
  write_meta "$state" malformed "$worktree"
  out=$(run_check "$dir" malformed)
  [ -z "$out" ] || fail "malformed Boulder state must stay silent: $out"
  pass "malformed Boulder state stays silent"

  dir=$(new_case completed)
  state="$dir/state"; worktree="$dir/worktree"; plan="$worktree/.omo/plans/completed.md"
  printf '%s\n' '- [x] 1. first' '- [X] 2. second' > "$plan"
  write_boulder "$worktree" '.omo/plans/completed.md'
  run_brief "$dir" completed
  write_meta "$state" completed "$worktree"
  before=$(sha256 "$plan")
  out=$(run_check "$dir" completed)
  after=$(sha256 "$plan")
  [ "$out" = 'plan progress: remaining=0 total=2' ] \
    || fail "completed plan did not report zero remaining: $out"
  [ "$before" = "$after" ] || fail "completed-plan probe mutated the plan"
  pass "completed plan reports zero remaining"

  dir=$(new_case missing-plan)
  state="$dir/state"; worktree="$dir/worktree"
  write_boulder "$worktree" '.omo/plans/missing.md'
  run_brief "$dir" missing
  write_meta "$state" missing "$worktree"
  out=$(run_check "$dir" missing)
  [ -z "$out" ] || fail "missing plan must stay silent: $out"
  pass "missing plan stays silent"
}

test_happy_path_reports_changed_progress_and_preserves_plan
test_edge_cases_are_silent_or_report_completed_plan

pass "plan progress behavior"
