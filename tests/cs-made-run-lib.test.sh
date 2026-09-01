#!/usr/bin/env bash
# Behavior tests for bin/cs-made-run-lib.sh - the single owner of the made run
# ATTRIBUTION contract shared by cs-crew-state.sh (reads a soldier's state) and
# cs-teardown.sh (concludes a parked run before cleanup). These pin the pure
# predicates directly, over real throwaway git repos, so the head-identity and
# parked-gate rules cannot drift unnoticed under either consumer. The TOON
# builders mirror what the bounded `made` call this library wraps is expected
# to emit (formerly `no-mistakes axi status`; see the library's own header for
# the CLI-surface caveat).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/cs-made-run-lib.sh
. "$ROOT/bin/cs-made-run-lib.sh"

TMP=$(cs_test_tmproot cs-made-run-lib)
cs_git_identity

# A repo on <branch> with <n> commits; echoes nothing (HEAD read per-test).
make_repo() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m c0
  git -C "$dir" checkout -q -b "$branch"
}

parked_toon() {  # <branch> <head>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: awaiting_approval
  head: "$2"
gate: review
EOF
}
gate_block_toon() {  # <branch> <head>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "$2"
gate:
  step: review
  status: fix_review
EOF
}
running_toon() {  # <branch> <head>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "$2"
  findings: none
EOF
}
cancelled_toon() {  # <branch> <head>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "$2"
outcome: cancelled
EOF
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

# --- cs_made_status_is_attributed -------------------------------------------
git -C "$WT" checkout -q cs/feat  # back to the c0-child tip
HEAD=$(git -C "$WT" rev-parse HEAD)
cs_made_status_is_attributed "$WT" cs/feat "$(parked_toon cs/feat "$HEAD")" \
  || fail "matching branch + head must attribute"
cs_made_status_is_attributed "$WT" cs/feat "$(parked_toon cs/other "$HEAD")" \
  && fail "a different branch must not attribute"
cs_made_status_is_attributed "$WT" cs/feat "$(parked_toon cs/feat "cafebabecafebabecafebabecafebabecafebabe")" \
  && fail "this branch at a rewritten head must not attribute"
pass "attribution requires both exact branch and current head"

# --- cs_made_run_is_gate_parked ---------------------------------------------
cs_made_run_is_gate_parked "$(parked_toon cs/feat "$HEAD")" \
  || fail "awaiting_approval run is parked"
cs_made_run_is_gate_parked "$(gate_block_toon cs/feat "$HEAD")" \
  || fail "fix_review gate block is parked"
cs_made_run_is_gate_parked "$(running_toon cs/feat "$HEAD")" \
  && fail "a plain running run is not parked"
cs_made_run_is_gate_parked "$(cancelled_toon cs/feat "$HEAD")" \
  && fail "a run with a terminal outcome is never parked"
pass "gate-parked predicate: gates park, running and terminal do not"

# --- field / quote parsing ---------------------------------------------------
[ "$(cs_made_strip_quotes "$(cs_made_field "$(parked_toon cs/feat "$HEAD")" branch)")" = cs/feat ] \
  || fail "branch field parses"
[ "$(cs_made_strip_quotes "$(cs_made_field "$(parked_toon cs/feat "$HEAD")" head)")" = "$HEAD" ] \
  || fail "quoted head field strips its quotes"
pass "TOON scalar field and quote stripping"

[ "$(cs_made_trim '   padded   ')" = padded ] || fail "trim strips leading/trailing space"
pass "trim primitive"

# --- cs_made_run / cs_made_axi_status_read: bounded call through `made` ------
# The renamed function set must exist and shell `made`, not `no-mistakes`.
type cs_made_run >/dev/null 2>&1 || fail "cs_made_run must exist"
type cs_made_trim >/dev/null 2>&1 || fail "cs_made_trim must exist"
if type cs_nm_run >/dev/null 2>&1; then
  fail "cs_nm_run must no longer exist"
fi
pass "renamed functions exist, old cs_nm_run does not"

MADEBIN="$TMP/made-bin"
mkdir -p "$MADEBIN"
cat > "$MADEBIN/made" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  axi)
    if [ "${2:-}" = status ]; then
      if [ "${CS_MADE_TEST_STATUS_FAIL:-0}" = 1 ]; then
        exit 17
      fi
      printf '%s\n' "${CS_MADE_TEST_STATUS:-}"
    fi
    ;;
  echo-args)
    shift
    printf '%s\n' "$*"
    ;;
esac
SH
chmod +x "$MADEBIN/made"

# cs_made_run wraps a bounded call to `made` (not `no-mistakes`): a fake
# `made` on PATH is reachable, and a fake `no-mistakes` on PATH is never
# invoked, proving the binary swap actually happened.
NOMISTAKESBIN="$TMP/no-mistakes-bin"
mkdir -p "$NOMISTAKESBIN"
cat > "$NOMISTAKESBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
echo "no-mistakes must never be called by cs_made_run" >&2
exit 99
SH
chmod +x "$NOMISTAKESBIN/no-mistakes"

[ "$(PATH="$MADEBIN:$NOMISTAKESBIN:$PATH" cs_made_run "$WT" 5 echo-args hello world)" = "hello world" ] \
  || fail "cs_made_run must shell the made CLI and return its stdout"
pass "cs_made_run wraps a bounded made call, equivalent to old cs_nm_run"

[ -z "$(PATH="$MADEBIN:$PATH" cs_made_axi_status_read "$WT" 1)" ] \
  || fail "a successful empty axi status remains readable"
PATH="$MADEBIN:$PATH" CS_MADE_TEST_STATUS_FAIL=1 \
  cs_made_axi_status_read "$WT" 1 >/dev/null 2>&1 \
  && fail "a failed axi status is unreadable"
pass "axi status reader preserves reachability"

pass "cs-made-run-lib attribution contract"
