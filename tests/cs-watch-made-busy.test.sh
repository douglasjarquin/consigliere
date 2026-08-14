#!/usr/bin/env bash
# Behavior: bin/cs-watch.sh's made_run_state / made_run_is_busy - the
# `made status --json` socket-query busy-detection that Task 28
# (plans/made-rewrite.md) adds in place of the old log-scraping description of
# an "actively-running no-mistakes step". Covers the two mandated scenarios:
# a running/queued made run reads as busy, and an unreachable made daemon (or
# missing made binary) reads as the DISTINCT `unreachable` state - never a
# silent idle/busy guess and never a fallback to scraped log content.
#
# Hermetic: a fake `made` on PATH answers `status --json` from a fixture file
# (mirrors tests/cs-made-lib.test.sh's fake, the seam Task 24 established).
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

# --- busy: a running made run reads as busy ---------------------------------

cat > "$FAKEBIN/made" <<SCRIPT
#!/usr/bin/env bash
if [ "\${1:-}" = status ] && [ "\${2:-}" = --json ]; then
  cat "$STATUS_JSON"
  exit 0
fi
exit 1
SCRIPT
chmod +x "$FAKEBIN/made"
export PATH="$FAKEBIN:$PATH"

printf '{"schema_version":1,"run_id":"run-1","repo":"acme/widgets","branch":"feature/x","state":"running","queued_at":"","started_at":"2026-08-13T00:00:00Z","ended_at":"","error":"","stages":[],"pending_findings":[]}\n' > "$STATUS_JSON"
state=$(made_run_state)
[ "$state" = busy ] || fail "made_run_state must report busy for state=running, got '$state'"
made_run_is_busy || fail "made_run_is_busy must succeed (0) for state=running"
pass "made_run_state/made_run_is_busy report busy for a running made run"

printf '{"schema_version":1,"run_id":"run-2","repo":"acme/widgets","branch":"feature/x","state":"queued","queued_at":"2026-08-13T00:00:00Z","started_at":"","ended_at":"","error":"","stages":[],"pending_findings":[]}\n' > "$STATUS_JSON"
state=$(made_run_state)
[ "$state" = busy ] || fail "made_run_state must report busy for state=queued, got '$state'"
pass "made_run_state reports busy for a queued made run"

# --- idle: a completed/failed made run is NOT busy --------------------------

printf '{"schema_version":1,"run_id":"run-3","repo":"acme/widgets","branch":"feature/x","state":"completed","queued_at":"","started_at":"","ended_at":"2026-08-13T00:01:00Z","error":"","stages":[],"pending_findings":[]}\n' > "$STATUS_JSON"
state=$(made_run_state)
[ "$state" = idle ] || fail "made_run_state must report idle for state=completed, got '$state'"
made_run_is_busy && fail "made_run_is_busy must fail (non-zero) for state=completed"
pass "made_run_state/made_run_is_busy report idle for a completed made run"

printf '{"schema_version":1,"run_id":"run-4","repo":"acme/widgets","branch":"feature/x","state":"failed","queued_at":"","started_at":"","ended_at":"2026-08-13T00:01:00Z","error":"boom","stages":[],"pending_findings":[]}\n' > "$STATUS_JSON"
state=$(made_run_state)
[ "$state" = idle ] || fail "made_run_state must report idle for state=failed, got '$state'"
pass "made_run_state reports idle for a failed made run"

# --- unreachable: daemon down (non-zero exit) is DISTINCT, not idle/busy ----

cat > "$FAKEBIN/made" <<'SCRIPT'
#!/usr/bin/env bash
echo "made: daemon not running" >&2
exit 1
SCRIPT
chmod +x "$FAKEBIN/made"
state=$(made_run_state)
[ "$state" = unreachable ] || fail "made_run_state must report unreachable when made exits non-zero, got '$state'"
made_run_is_busy && fail "made_run_is_busy must fail (non-zero, not busy) when made is unreachable"
pass "made_run_state reports unreachable when made's daemon is down, never a false idle/busy"

# --- unreachable: made binary missing entirely ------------------------------

EMPTYBIN="$TMP/emptybin"
mkdir -p "$EMPTYBIN"
state=$(PATH="$EMPTYBIN" made_run_state)
[ "$state" = unreachable ] || fail "made_run_state must report unreachable when made is not on PATH, got '$state'"
pass "made_run_state reports unreachable when the made binary is missing"

# --- unreachable: made exits 0 but prints unparseable/empty JSON -----------

cat > "$FAKEBIN/made" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
chmod +x "$FAKEBIN/made"
state=$(made_run_state)
[ "$state" = unreachable ] || fail "made_run_state must report unreachable on empty output, got '$state'"
pass "made_run_state reports unreachable on empty made status output"

pass "cs-watch.sh made-status busy-detection: busy/idle/unreachable are all distinct and correct"
