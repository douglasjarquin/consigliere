#!/usr/bin/env bash
# Behavior tests for bin/cs-made-run-lib.sh - the single owner of the made run
# ATTRIBUTION contract shared by cs-crew-state.sh (reads a soldier's state) and
# cs-teardown.sh (concludes a slot-holding run before cleanup). These pin the
# pure predicates directly, over real throwaway git repos, so the head-identity
# and branch-filtering rules cannot drift unnoticed under either consumer.
# JSON fixtures below are shaped like made's real StatusReport/run-list output
# (docs/made.md), never the old TOON/axi shape this replaces.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/cs-made-run-lib.sh
. "$ROOT/bin/cs-made-run-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "1..0 # skip jq is required"; exit 0; }

TMP=$(cs_test_tmproot cs-made-run-lib)
cs_git_identity

# A repo on <branch> with 1 commit; echoes nothing (HEAD read per-test).
make_repo() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m c0
  git -C "$dir" checkout -q -b "$branch"
}

# One StatusReport-shaped row. <branch> <state> <output_sha> [<queued_at>] [<input_sha>]
run_row() {
  local branch=$1 state=$2 output_sha=$3 queued_at=${4:-2026-07-02T22:00:00Z} input_sha=${5:-$3}
  jq -nc --arg branch "$branch" --arg state "$state" --arg out "$output_sha" \
    --arg qat "$queued_at" --arg in "$input_sha" \
    '{branch: $branch, state: $state, output_sha: $out, input_sha: $in, queued_at: $qat,
      run_id: ("run-" + $out), pr_url: "", pending_findings: []}'
}

# A {"runs":[...]} listing from N row JSON args.
run_list() {
  jq -sc '{schema_version: 1, protocol_version: 1, runs: .}' <<<"$(printf '%s\n' "$@")"
}

# --- cs_made_head_matches_worktree ------------------------------------------
WT="$TMP/wt"
make_repo "$WT" cs/feat
HEAD=$(git -C "$WT" rev-parse HEAD)

cs_made_head_matches_worktree "$WT" "$HEAD" || fail "equal head must match"
pass "equal head matches"

# Advance the run head one commit past the worktree: worktree HEAD is an ancestor
# of the run head (pipeline fix commit) -> still a match.
git -C "$WT" commit -q --allow-empty -m fix
FIX_HEAD=$(git -C "$WT" rev-parse HEAD)
cs_made_head_matches_worktree "$WT" "$FIX_HEAD" || fail "descendant run head must match"
# From the fix commit's point of view, the earlier c0-child head is a strict
# ancestor of the worktree HEAD: local work advanced past it -> no match.
cs_made_head_matches_worktree "$WT" "$HEAD" && fail "strict-ancestor run head must not match"
pass "ancestor rules: descendant matches, strict-ancestor does not"

cs_made_head_matches_worktree "$WT" "" && fail "empty head must not match"
cs_made_head_matches_worktree "$WT" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
  && fail "unresolvable head must not match"
pass "empty and unresolvable heads do not match"

git -C "$WT" checkout -q cs/feat  # back to the c0-child tip
HEAD=$(git -C "$WT" rev-parse HEAD)

# --- cs_made_resolve_run: fake made ------------------------------------------
MADEBIN="$TMP/made-bin"
mkdir -p "$MADEBIN"
ACTIVE_JSON="$TMP/active.json"
FULL_JSON="$TMP/full.json"
: > "$ACTIVE_JSON"
: > "$FULL_JSON"
cat > "$MADEBIN/made" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-} \${3:-}" in
  "run list --json")
    if [ "\${4:-}" = "--active" ]; then
      cat "$ACTIVE_JSON"
    else
      cat "$FULL_JSON"
    fi
    ;;
esac
SH
chmod +x "$MADEBIN/made"

with_made() { PATH="$MADEBIN:$PATH" "$@"; }

run_list "$(run_row cs/other running "$HEAD")" > "$ACTIVE_JSON"
echo '{"schema_version":1,"protocol_version":1,"runs":[]}' > "$FULL_JSON"
out=$(with_made cs_made_resolve_run "$WT" 5 cs/other) || fail "resolve_run must find an active run for the branch at the exact head"
[ "$(printf '%s' "$out" | jq -r '.branch')" = cs/other ] || fail "resolved row must be for cs/other"
pass "resolve_run finds an active run for the branch at the exact head"

run_list "$(run_row cs/other running "$HEAD")" > "$ACTIVE_JSON"
run_list "$(run_row cs/feat failed "$HEAD")" > "$FULL_JSON"
out=$(with_made cs_made_resolve_run "$WT" 5 cs/feat) || fail "resolve_run must fall back to the full listing for a terminal run"
[ "$(printf '%s' "$out" | jq -r '.state')" = failed ] || fail "resolved row must report the failed state"
pass "resolve_run falls back to the full listing for a terminal (non-active) run"

run_list "$(run_row cs/feat running deadbeefdeadbeefdeadbeefdeadbeefdeadbeef)" > "$ACTIVE_JSON"
run_list "$(run_row cs/feat running deadbeefdeadbeefdeadbeefdeadbeefdeadbeef)" > "$FULL_JSON"
with_made cs_made_resolve_run "$WT" 5 cs/feat >/dev/null \
  && fail "resolve_run must ignore a same-branch row at a diverged head"
pass "resolve_run ignores a same-branch row at a diverged head"

run_list "$(run_row cs/other running "$HEAD")" > "$ACTIVE_JSON"
: > "$FULL_JSON"
echo '{"schema_version":1,"protocol_version":1,"runs":[]}' > "$FULL_JSON"
with_made cs_made_resolve_run "$WT" 5 cs/feat >/dev/null \
  && fail "resolve_run must ignore a different branch's row"
pass "resolve_run ignores a different branch's row"

run_list "$(run_row cs/feat running "$HEAD" 2026-07-02T20:00:00Z)" \
         "$(run_row cs/feat awaiting_review "$HEAD" 2026-07-02T22:00:00Z)" > "$ACTIVE_JSON"
: > "$FULL_JSON"
echo '{"schema_version":1,"protocol_version":1,"runs":[]}' > "$FULL_JSON"
out=$(with_made cs_made_resolve_run "$WT" 5 cs/feat) || fail "resolve_run must find one of the two matching rows"
[ "$(printf '%s' "$out" | jq -r '.state')" = awaiting_review ] \
  || fail "resolve_run must pick the row with the later queued_at, got state=$(printf '%s' "$out" | jq -r '.state')"
pass "resolve_run picks the most recent of two same-branch matching rows by queued_at"

echo '{"schema_version":1,"protocol_version":1,"runs":[]}' > "$ACTIVE_JSON"
echo '{"schema_version":1,"protocol_version":1,"runs":[]}' > "$FULL_JSON"
out=""
with_made cs_made_resolve_run "$WT" 5 cs/feat && fail "resolve_run must return non-zero when nothing matches"
out=$(with_made cs_made_resolve_run "$WT" 5 cs/feat 2>/dev/null || true)
[ -z "$out" ] || fail "resolve_run must print nothing when nothing matches, got: $out"
pass "resolve_run returns empty (not an error exit that looks like a crash) when nothing matches anywhere"

row_with_both_shas=$(jq -nc --arg branch cs/feat --arg out "$HEAD" --arg in deadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
  '{branch: $branch, state: "running", output_sha: $out, input_sha: $in, queued_at: "2026-07-02T22:00:00Z", run_id: "run-x", pr_url: "", pending_findings: []}')
run_list "$row_with_both_shas" > "$ACTIVE_JSON"
echo '{"schema_version":1,"protocol_version":1,"runs":[]}' > "$FULL_JSON"
with_made cs_made_resolve_run "$WT" 5 cs/feat >/dev/null \
  || fail "resolve_run must prefer output_sha (matching HEAD) over a stale input_sha"
pass "resolve_run prefers output_sha over input_sha when both are present"

row_output_empty=$(jq -nc --arg branch cs/feat --arg in "$HEAD" \
  '{branch: $branch, state: "running", output_sha: "", input_sha: $in, queued_at: "2026-07-02T22:00:00Z", run_id: "run-y", pr_url: "", pending_findings: []}')
run_list "$row_output_empty" > "$ACTIVE_JSON"
echo '{"schema_version":1,"protocol_version":1,"runs":[]}' > "$FULL_JSON"
with_made cs_made_resolve_run "$WT" 5 cs/feat >/dev/null \
  || fail "resolve_run must fall back to input_sha when output_sha is empty"
pass "resolve_run falls back to input_sha when output_sha is empty"

# --- old TOON/axi functions are gone -----------------------------------------
for fn in cs_made_trim cs_made_strip_quotes cs_made_field cs_made_findings_count \
          cs_made_gate_step_row cs_made_gate_status cs_made_has_gate \
          cs_made_gate_line_name cs_made_gate_name cs_made_gate_findings_count \
          cs_made_axi_status cs_made_axi_status_read cs_made_runs_status_for_branch \
          cs_made_runs_status_for_branch_read cs_made_status_is_attributed \
          cs_made_run_is_gate_parked cs_made_run_status_is_active; do
  if type "$fn" >/dev/null 2>&1; then
    fail "$fn must no longer exist"
  fi
done
type cs_made_run >/dev/null 2>&1 || fail "cs_made_run must exist"
type cs_made_resolve_run >/dev/null 2>&1 || fail "cs_made_resolve_run must exist"
pass "renamed functions exist, old TOON/axi functions do not"

# --- cs_made_run: bounded call through `made`, not `no-mistakes` ------------
NOMISTAKESBIN="$TMP/no-mistakes-bin"
mkdir -p "$NOMISTAKESBIN"
cat > "$NOMISTAKESBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
echo "no-mistakes must never be called by cs_made_run" >&2
exit 99
SH
chmod +x "$NOMISTAKESBIN/no-mistakes"

ECHOBIN="$TMP/echo-bin"
mkdir -p "$ECHOBIN"
cat > "$ECHOBIN/made" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*"
SH
chmod +x "$ECHOBIN/made"

[ "$(PATH="$ECHOBIN:$NOMISTAKESBIN:$PATH" cs_made_run "$WT" 5 hello world)" = "hello world" ] \
  || fail "cs_made_run must shell the made CLI and return its stdout"
pass "cs_made_run wraps a bounded made call, equivalent to old cs_nm_run"

pass "cs-made-run-lib attribution contract"
