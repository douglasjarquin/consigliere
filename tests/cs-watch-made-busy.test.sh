#!/usr/bin/env bash
# Behavior: bin/cs-watch.sh's made_run_state / made_run_is_busy - busy
# detection read directly from made's real `run status --json` output
# (docs/made.md), off the StatusReport's own execution_finished boolean
# rather than a re-derived state-string allowlist: false (queued/running/
# awaiting_review) -> busy, true (awaiting_merge plus every terminal state)
# -> idle. An unreachable made daemon (or missing made binary, or empty/
# unparseable output) reads as the DISTINCT `unreachable` state - never a
# silent idle/busy guess and never a fallback to scraped log content.
#
# Hermetic: a fake `made` on PATH answers `run status --json <run-id>` from a
# fixture file (mirrors tests/cs-made-lib.test.sh's fake). <run-id> is
# mandatory in the real contract (no "latest" any more), so every call below
# passes one explicitly.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "1..0 # skip jq is required"; exit 0; }

TMP=$(cs_test_tmproot cs-watch-made-busy)
FAKEBIN=$(cs_fakebin "$TMP")
STATUS_JSON="$TMP/status.json"

# Source cs-watch.sh for its functions only: it returns before the singleton
# lock / blocking loop whenever BASH_SOURCE differs from $0 (see its own
# "Main entry" guard), the same pattern tests/cs-watch-triage.test.sh relies
# on for subprocess runs - this sources it in-process instead, for a direct
# unit test of made_run_state/made_run_is_busy with no watcher loop involved.
export CS_STATE_OVERRIDE="$TMP/state"
mkdir -p "$CS_STATE_OVERRIDE"
# shellcheck source=bin/cs-watch.sh
. "$ROOT/bin/cs-watch.sh"

row() {  # <state> <execution_finished>
  printf '{"schema_version":1,"run_id":"run-1","repo":"acme/widgets","branch":"feature/x","state":"%s","execution_finished":%s,"input_sha":"a","output_sha":"b","error":"","errors":[],"pr_url":"","stages":[],"pending_findings":[]}\n' "$1" "$2"
}

# --- busy: queued/running/awaiting_review (execution_finished=false) -------

cat > "$FAKEBIN/made" <<SCRIPT
#!/usr/bin/env bash
if [ "\${1:-}" = run ] && [ "\${2:-}" = status ] && [ "\${3:-}" = --json ]; then
  cat "$STATUS_JSON"
  exit 0
fi
exit 1
SCRIPT
chmod +x "$FAKEBIN/made"
export PATH="$FAKEBIN:$PATH"

row running false > "$STATUS_JSON"
state=$(made_run_state run-1)
[ "$state" = busy ] || fail "made_run_state must report busy for state=running, got '$state'"
made_run_is_busy run-1 || fail "made_run_is_busy must succeed (0) for state=running"
pass "made_run_state/made_run_is_busy report busy for a running made run"

row queued false > "$STATUS_JSON"
state=$(made_run_state run-1)
[ "$state" = busy ] || fail "made_run_state must report busy for state=queued, got '$state'"
pass "made_run_state reports busy for a queued made run"

row awaiting_review false > "$STATUS_JSON"
state=$(made_run_state run-1)
[ "$state" = busy ] || fail "made_run_state must report busy for state=awaiting_review, got '$state'"
pass "made_run_state reports busy for an awaiting_review made run"

# --- idle: awaiting_merge and every terminal state (execution_finished=true)

row succeeded true > "$STATUS_JSON"
state=$(made_run_state run-1)
[ "$state" = idle ] || fail "made_run_state must report idle for state=succeeded, got '$state'"
made_run_is_busy run-1 && fail "made_run_is_busy must fail (non-zero) for state=succeeded"
pass "made_run_state/made_run_is_busy report idle for a succeeded made run"

row failed true > "$STATUS_JSON"
state=$(made_run_state run-1)
[ "$state" = idle ] || fail "made_run_state must report idle for state=failed, got '$state'"
pass "made_run_state reports idle for a failed made run"

row awaiting_merge true > "$STATUS_JSON"
state=$(made_run_state run-1)
[ "$state" = idle ] || fail "made_run_state must report idle for state=awaiting_merge, got '$state'"
pass "made_run_state reports idle for an awaiting_merge made run"

row canceled true > "$STATUS_JSON"
state=$(made_run_state run-1)
[ "$state" = idle ] || fail "made_run_state must report idle for state=canceled, got '$state'"
row superseded true > "$STATUS_JSON"
state=$(made_run_state run-1)
[ "$state" = idle ] || fail "made_run_state must report idle for state=superseded, got '$state'"
pass "made_run_state reports idle for canceled and superseded runs"

# --- unreachable: daemon down (non-zero exit) is DISTINCT, not idle/busy ----

cat > "$FAKEBIN/made" <<'SCRIPT'
#!/usr/bin/env bash
echo "made run status: daemon not reachable" >&2
exit 1
SCRIPT
chmod +x "$FAKEBIN/made"
state=$(made_run_state run-1)
[ "$state" = unreachable ] || fail "made_run_state must report unreachable when made exits non-zero, got '$state'"
made_run_is_busy run-1 && fail "made_run_is_busy must fail (non-zero, not busy) when made is unreachable"
pass "made_run_state reports unreachable when made's daemon is down, never a false idle/busy"

# --- unreachable: made binary missing entirely ------------------------------

EMPTYBIN="$TMP/emptybin"
mkdir -p "$EMPTYBIN"
state=$(PATH="$EMPTYBIN" made_run_state run-1)
[ "$state" = unreachable ] || fail "made_run_state must report unreachable when made is not on PATH, got '$state'"
pass "made_run_state reports unreachable when the made binary is missing"

# --- unreachable: made exits 0 but prints unparseable/empty JSON -----------

cat > "$FAKEBIN/made" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
chmod +x "$FAKEBIN/made"
state=$(made_run_state run-1)
[ "$state" = unreachable ] || fail "made_run_state must report unreachable on empty output, got '$state'"
pass "made_run_state reports unreachable on empty made status output"

# --- unreachable: called with no run-id at all ------------------------------

row running false > "$STATUS_JSON"
cat > "$FAKEBIN/made" <<SCRIPT
#!/usr/bin/env bash
if [ "\${1:-}" = run ] && [ "\${2:-}" = status ] && [ "\${3:-}" = --json ]; then
  cat "$STATUS_JSON"
  exit 0
fi
exit 1
SCRIPT
chmod +x "$FAKEBIN/made"
state=$(made_run_state)
[ "$state" = unreachable ] || fail "made_run_state must report unreachable with no run-id (made's run.status has no 'latest'), got '$state'"
pass "made_run_state reports unreachable when called with no run-id at all"

pass "cs-watch.sh made-status busy-detection: busy/idle/unreachable are all distinct and correct"
