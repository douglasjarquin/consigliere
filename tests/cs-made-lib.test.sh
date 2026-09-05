#!/usr/bin/env bash
# Behavior: cs-made-lib.sh is a thin shellout layer over the `made` CLI
# (mirrors cs-herdr-lib.sh's role for herdr). This suite stubs a fake `made`
# on PATH (tests/fakebin/made, generated per-case below) so it exercises the
# argument-forwarding contract hermetically, without a real made daemon.
#
# Covers made's real CLI surface (docs/made.md): cs_made_status forwards to
# `made run status --json <run-id>` (run-id mandatory - no "latest" any more),
# cs_made_run_list/cs_made_run_cancel/cs_made_review_decide wrap made's real
# run-list/cancel/review-decide surface, cs_made_daemon_start detaches and
# polls doctor instead of blocking, and every other wrapper forwards to the
# right `made` subcommand with the right arguments and working directory.
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

# --- fake made: logs argv, answers a handful of real subcommands from fixtures
STATUS_JSON="$TMP/status.json"
RUN_LIST_JSON="$TMP/run-list.json"
DOCTOR_JSON="$TMP/doctor.json"
DAEMON_START_LOG="$TMP/daemon-start.log"
: > "$DAEMON_START_LOG"
printf '{"checks":{"daemon":"reachable"}}\n' > "$DOCTOR_JSON"
cat > "$FAKEBIN/made" <<SCRIPT
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALL_LOG"
printf '%s\t%s\n' "\$(pwd)" "\$*" >> "$CALL_LOG.pwd"
case "\${1:-} \${2:-}" in
  "run status")
    cat "$STATUS_JSON"; exit 0 ;;
  "run list")
    cat "$RUN_LIST_JSON"; exit 0 ;;
  "run cancel")
    id="\${4:-}"
    printf '{"schema_version":1,"run_id":"%s","state":"canceled","input_sha":"a","output_sha":"b"}\n' "\$id"
    exit 0 ;;
  "review decide")
    shift
    stage="" decision="" rid=""
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --stage) stage=\$2; shift 2 ;;
        --decision) decision=\$2; shift 2 ;;
        --json) shift ;;
        *) rid=\$1; shift ;;
      esac
    done
    printf '{"schema_version":1,"run_id":"%s","stage":"%s","decision":"%s"}\n' "\$rid" "\$stage" "\$decision"
    exit 0 ;;
  "doctor --json")
    cat "$DOCTOR_JSON"; exit 0 ;;
  "daemon start")
    echo started >> "$DAEMON_START_LOG"
    exit 0 ;;
esac
exit 0
SCRIPT
chmod +x "$FAKEBIN/made"
export PATH="$FAKEBIN:$PATH"

reset_log() { : > "$CALL_LOG"; : > "$CALL_LOG.pwd"; }

# --- cs_made_status: forwards to `made run status --json <run-id>` ----------

cat > "$STATUS_JSON" <<'JSON'
{
  "schema_version": 1,
  "run_id": "run-42",
  "repo": "acme/widgets",
  "branch": "feature/x",
  "state": "running",
  "input_sha": "aaa",
  "output_sha": "bbb",
  "execution_finished": false,
  "error": "",
  "stages": [{"name": "intent", "result": "pass"}],
  "pending_findings": []
}
JSON

reset_log
out=$(cs_made_status run-42) || fail "cs_made_status must succeed against a mocked made"
run_id=$(printf '%s' "$out" | jq -r '.run_id')
[ "$run_id" = run-42 ] || fail "cs_made_status must echo made's run_id, got '$run_id'"
state=$(printf '%s' "$out" | jq -r '.state')
[ "$state" = running ] || fail "cs_made_status must echo made's state, got '$state'"
assert_line "$(cat "$CALL_LOG")" '^run status --json run-42$' "cs_made_status forwards to 'made run status --json <run-id>'"
pass "cs_made_status forwards to made run status --json <run-id>"

reset_log
err=0
cs_made_status >/dev/null 2>&1 || err=$?
[ "$err" -ne 0 ] || fail "cs_made_status must refuse a missing run-id"
[ ! -s "$CALL_LOG" ] || fail "cs_made_status must not shell out when the run-id is missing"
pass "cs_made_status refuses a missing run-id"

# --- cs_made_run_list: forwards to `made run list --json [--active]` -------

cat > "$RUN_LIST_JSON" <<'JSON'
{"schema_version": 1, "protocol_version": 1, "runs": []}
JSON

reset_log
cs_made_run_list >/dev/null || fail "cs_made_run_list must succeed against the stub"
assert_line "$(cat "$CALL_LOG")" '^run list --json$' "cs_made_run_list calls 'made run list --json'"
pass "cs_made_run_list forwards to made run list --json"

reset_log
cs_made_run_list --active >/dev/null || fail "cs_made_run_list --active must succeed against the stub"
assert_line "$(cat "$CALL_LOG")" '^run list --json --active$' "cs_made_run_list --active calls 'made run list --json --active'"
pass "cs_made_run_list forwards --active"

reset_log
err=0
cs_made_run_list --bogus >/dev/null 2>&1 || err=$?
[ "$err" -ne 0 ] || fail "cs_made_run_list must refuse an unrecognized argument"
[ ! -s "$CALL_LOG" ] || fail "cs_made_run_list must not shell out on an unrecognized argument"
pass "cs_made_run_list refuses an unrecognized argument"

# --- cs_made_run_cancel: forwards to `made run cancel --json <run-id>` -----

reset_log
out=$(cs_made_run_cancel run-42) || fail "cs_made_run_cancel must succeed against the stub"
rid=$(printf '%s' "$out" | jq -r '.run_id')
[ "$rid" = run-42 ] || fail "cs_made_run_cancel must echo the fixture's run_id, got '$rid'"
assert_line "$(cat "$CALL_LOG")" '^run cancel --json run-42$' "cs_made_run_cancel calls 'made run cancel --json <run-id>'"
pass "cs_made_run_cancel forwards to made run cancel --json <run-id>"

reset_log
err=0
cs_made_run_cancel >/dev/null 2>&1 || err=$?
[ "$err" -ne 0 ] || fail "cs_made_run_cancel must refuse a missing run-id"
[ ! -s "$CALL_LOG" ] || fail "cs_made_run_cancel must not shell out when the run-id is missing"
pass "cs_made_run_cancel refuses a missing run-id"

# --- cs_made_review_decide: forwards to `made review decide --json ...` ----

reset_log
out=$(cs_made_review_decide run-42 review approved) || fail "cs_made_review_decide must succeed against the stub"
decision=$(printf '%s' "$out" | jq -r '.decision')
[ "$decision" = approved ] || fail "cs_made_review_decide must echo the fixture's decision, got '$decision'"
assert_line "$(cat "$CALL_LOG")" '^review decide --json --stage review --decision approved run-42$' \
  "cs_made_review_decide calls 'made review decide --json --stage <stage> --decision <decision> <run-id>'"
pass "cs_made_review_decide forwards to made review decide --json --stage --decision <run-id>"

reset_log
err=0
cs_made_review_decide run-42 review maybe >/dev/null 2>&1 || err=$?
[ "$err" -ne 0 ] || fail "cs_made_review_decide must refuse a decision other than approved/rejected"
[ ! -s "$CALL_LOG" ] || fail "cs_made_review_decide must not shell out on an invalid decision"
pass "cs_made_review_decide refuses a decision other than approved/rejected without shelling out"

# --- gate init / doctor / daemon stop: exact forwarding, unchanged ----------

reset_log
# shellcheck disable=SC2119  # cs_made_gate_init deliberately takes no args here: this case asserts the bare forwarding
cs_made_gate_init >/dev/null || fail "cs_made_gate_init must succeed against the stub"
assert_line "$(cat "$CALL_LOG")" '^gate init$' "cs_made_gate_init calls 'made gate init'"
pass "cs_made_gate_init forwards to made gate init"

reset_log
cs_made_doctor --json >/dev/null || fail "cs_made_doctor must succeed against the stub"
assert_line "$(cat "$CALL_LOG")" '^doctor --json$' "cs_made_doctor calls 'made doctor --json'"
pass "cs_made_doctor forwards to made doctor"

reset_log
# shellcheck disable=SC2119  # cs_made_daemon_stop deliberately takes no args here: this case asserts the bare forwarding
cs_made_daemon_stop >/dev/null || fail "cs_made_daemon_stop must succeed against the stub"
assert_line "$(cat "$CALL_LOG")" '^daemon stop$' "cs_made_daemon_stop calls 'made daemon stop'"
pass "cs_made_daemon_stop forwards to made daemon stop"

# --- cs_made_daemon_start: detach + poll doctor, never a blocking passthrough

printf '{"checks":{"daemon":"reachable"}}\n' > "$DOCTOR_JSON"
reset_log
: > "$DAEMON_START_LOG"
cs_made_daemon_start || fail "cs_made_daemon_start must return 0 when already reachable"
[ ! -s "$DAEMON_START_LOG" ] || fail "cs_made_daemon_start must never start a second daemon when already reachable"
pass "cs_made_daemon_start returns immediately when the daemon is already reachable, never starts a second daemon"

# Comes up after being started: doctor answers unreachable until made daemon
# start has been invoked at least once (fake bumps a counter file).
COME_UP_MARK="$TMP/came-up"
rm -f "$COME_UP_MARK"
cat > "$FAKEBIN/made" <<SCRIPT
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALL_LOG"
case "\${1:-} \${2:-}" in
  "doctor --json")
    if [ -f "$COME_UP_MARK" ]; then
      printf '{"checks":{"daemon":"reachable"}}\n'
    else
      printf '{"checks":{"daemon":"unreachable"}}\n'
    fi
    exit 0 ;;
  "daemon start")
    touch "$COME_UP_MARK"
    exit 0 ;;
esac
exit 0
SCRIPT
chmod +x "$FAKEBIN/made"
reset_log
cs_made_daemon_start "$TMP/daemon.log" 5 || fail "cs_made_daemon_start must return 0 once doctor reports reachable"
grep -q '^daemon start$' "$CALL_LOG" || fail "cs_made_daemon_start must have invoked made daemon start"
pass "cs_made_daemon_start detaches and starts the daemon when down, returns once doctor reports reachable"

# Never comes up: must time out loudly, not hang.
cat > "$FAKEBIN/made" <<SCRIPT
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "doctor --json") printf '{"checks":{"daemon":"unreachable"}}\n'; exit 0 ;;
  "daemon start") exit 0 ;;
esac
exit 0
SCRIPT
chmod +x "$FAKEBIN/made"
start_ts=$(date +%s)
err=0
cs_made_daemon_start "$TMP/daemon2.log" 1 2>"$TMP/daemon-start.err" || err=$?
end_ts=$(date +%s)
[ "$err" -ne 0 ] || fail "cs_made_daemon_start must fail when the daemon never becomes reachable"
elapsed=$((end_ts - start_ts))
[ "$elapsed" -le 5 ] || fail "cs_made_daemon_start must not hang well past its timeout, took ${elapsed}s"
assert_grep "did not become reachable" "$TMP/daemon-start.err" "cs_made_daemon_start must name the timeout in its stderr"
pass "cs_made_daemon_start times out loudly (not hanging) when the daemon never becomes reachable"

# --- cs_made_require: fails clearly when made is missing --------------------

EMPTYBIN="$TMP/emptybin"
mkdir -p "$EMPTYBIN"
err=0
PATH="$EMPTYBIN" cs_made_require >/dev/null 2>&1 || err=$?
[ "$err" -ne 0 ] || fail "cs_made_require must fail when made is not on PATH"
pass "cs_made_require reports a missing made binary"

# --- header doc: cites docs/made.md, no axi vocabulary ----------------------

HDR="$ROOT/bin/cs-made-lib.sh"
assert_grep "docs/made.md" "$HDR" "header must cite docs/made.md for the verified-facts record"
assert_no_grep "made axi" "$HDR" "header must not describe any made axi subcommand as real or forward-referenced"
assert_no_grep "plans/made-rewrite.md" "$HDR" "header must not cite the nonexistent plans/made-rewrite.md"
pass "cs-made-lib header cites docs/made.md, not plans/made-rewrite.md"

pass "cs-made-lib shim forwards to the made CLI"
