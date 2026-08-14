#!/usr/bin/env bash
# Behavior: cs-made-lib.sh is a thin shellout layer over the `made` CLI
# (mirrors cs-herdr-lib.sh's role for herdr). This suite stubs a fake `made`
# on PATH (tests/fakebin/made, generated per-case below) so it exercises the
# argument-forwarding contract hermetically, without a real made daemon.
#
# Covers Task 24's two mandated checks: (1) cs_made_status returns/echoes
# `made status --json`'s fields correctly (parsed here via jq, matching how
# Task 26's cs-crew-state.sh migration will consume it), and (2) every other
# wrapper (cs_made_gate_init, cs_made_doctor, cs_made_daemon_start/stop,
# cs_made_abort) forwards to the right `made` subcommand with the right
# arguments and working directory.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "1..0 # skip jq is required"; exit 0; }

TMP=$(cs_test_tmproot cs-made-lib)
FAKEBIN=$(cs_fakebin "$TMP")
CALL_LOG="$TMP/made-calls.log"
: > "$CALL_LOG"

# shellcheck source=bin/cs-made-lib.sh
. "$ROOT/bin/cs-made-lib.sh"

# --- fake made: logs argv, answers `status --json` from a fixture file ------
STATUS_JSON="$TMP/status.json"
cat > "$FAKEBIN/made" <<SCRIPT
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALL_LOG"
printf '%s\t%s\n' "\$(pwd)" "\$*" >> "$CALL_LOG.pwd"
if [ "\${1:-}" = status ] && [ "\${2:-}" = --json ]; then
  cat "$STATUS_JSON"
  exit 0
fi
exit 0
SCRIPT
chmod +x "$FAKEBIN/made"
export PATH="$FAKEBIN:$PATH"

reset_log() { : > "$CALL_LOG"; : > "$CALL_LOG.pwd"; }

# --- cs_made_status: echoes made's JSON, fields parse with jq --------------

cat > "$STATUS_JSON" <<'JSON'
{
  "schema_version": 1,
  "run_id": "run-42",
  "repo": "acme/widgets",
  "branch": "feature/x",
  "state": "passed",
  "queued_at": "2026-08-13T00:00:00Z",
  "started_at": "2026-08-13T00:00:01Z",
  "ended_at": "2026-08-13T00:01:00Z",
  "error": "",
  "stages": [{"name": "intent", "result": "pass"}],
  "pending_findings": []
}
JSON

reset_log
out=$(cs_made_status) || fail "cs_made_status must succeed against a mocked made"
run_id=$(printf '%s' "$out" | jq -r '.run_id')
[ "$run_id" = run-42 ] || fail "cs_made_status must echo made's run_id, got '$run_id'"
state=$(printf '%s' "$out" | jq -r '.state')
[ "$state" = passed ] || fail "cs_made_status must echo made's state, got '$state'"
repo=$(printf '%s' "$out" | jq -r '.repo')
[ "$repo" = acme/widgets ] || fail "cs_made_status must echo made's repo, got '$repo'"
assert_line "$(cat "$CALL_LOG")" '^status --json$' "cs_made_status with no argument calls plain 'made status --json'"
pass "cs_made_status echoes made status --json's parsed fields"

# --- cs_made_status <run-id>: forwards the run-id positionally --------------

reset_log
out=$(cs_made_status run-42) || fail "cs_made_status <run-id> must succeed"
run_id=$(printf '%s' "$out" | jq -r '.run_id')
[ "$run_id" = run-42 ] || fail "cs_made_status <run-id> must still echo the fixture's run_id, got '$run_id'"
assert_line "$(cat "$CALL_LOG")" '^status --json run-42$' "cs_made_status <run-id> forwards it to 'made status --json <run-id>'"
pass "cs_made_status forwards an explicit run-id"

# --- gate init / doctor / daemon start / daemon stop: exact forwarding -----

reset_log
# shellcheck disable=SC2119  # cs_made_gate_init deliberately takes no args here: this case asserts the bare forwarding
cs_made_gate_init >/dev/null || fail "cs_made_gate_init must succeed against the stub"
assert_line "$(cat "$CALL_LOG")" '^gate init$' "cs_made_gate_init calls 'made gate init'"
pass "cs_made_gate_init forwards to made gate init"

reset_log
# shellcheck disable=SC2119  # cs_made_doctor deliberately takes no args here: this case asserts the bare forwarding
cs_made_doctor >/dev/null || fail "cs_made_doctor must succeed against the stub"
assert_line "$(cat "$CALL_LOG")" '^doctor$' "cs_made_doctor calls 'made doctor'"
pass "cs_made_doctor forwards to made doctor"

reset_log
# shellcheck disable=SC2119  # cs_made_daemon_start deliberately takes no args here: this case asserts the bare forwarding
cs_made_daemon_start >/dev/null || fail "cs_made_daemon_start must succeed against the stub"
assert_line "$(cat "$CALL_LOG")" '^daemon start$' "cs_made_daemon_start calls 'made daemon start'"
pass "cs_made_daemon_start forwards to made daemon start"

reset_log
# shellcheck disable=SC2119  # cs_made_daemon_stop deliberately takes no args here: this case asserts the bare forwarding
cs_made_daemon_stop >/dev/null || fail "cs_made_daemon_stop must succeed against the stub"
assert_line "$(cat "$CALL_LOG")" '^daemon stop$' "cs_made_daemon_stop calls 'made daemon stop'"
pass "cs_made_daemon_stop forwards to made daemon stop"

# --- cs_made_abort: runs `made axi abort` INSIDE the given worktree dir ----

WT="$TMP/worktree"
mkdir -p "$WT"
WT_REAL=$(cd "$WT" && pwd)
reset_log
cs_made_abort "$WT" >/dev/null || fail "cs_made_abort must succeed against the stub"
assert_line "$(cat "$CALL_LOG")" '^axi abort$' "cs_made_abort calls 'made axi abort'"
assert_line "$(cat "$CALL_LOG.pwd")" "^${WT_REAL}	axi abort\$" \
  "cs_made_abort runs made from inside the given worktree directory"
pass "cs_made_abort runs made axi abort from the given worktree"

# --- cs_made_require: fails clearly when made is missing --------------------

EMPTYBIN="$TMP/emptybin"
mkdir -p "$EMPTYBIN"
err=0
PATH="$EMPTYBIN" cs_made_require >/dev/null 2>&1 || err=$?
[ "$err" -ne 0 ] || fail "cs_made_require must fail when made is not on PATH"
pass "cs_made_require reports a missing made binary"

pass "cs-made-lib shim forwards to the made CLI"
