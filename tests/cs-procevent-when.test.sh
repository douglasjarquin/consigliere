#!/usr/bin/env bash
# Behavior tests for the condition->action process-event adapter (cs-procevent-when.sh).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(cs_test_tmproot cs-procevent-when)
export CS_PROCEVENT_CLAIM_ROOT="$TMP/claims"

pe()   { CS_HOME="$1" "$ROOT/bin/cs-procevent.sh" "${@:2}"; }
when() { CS_HOME="$1" "$ROOT/bin/cs-procevent-when.sh" "${@:2}"; }

WHEN_HOMES=()
when_teardown() {
  local home seen=$'\n'
  for home in ${WHEN_HOMES[@]+"${WHEN_HOMES[@]}"}; do
    case "$seen" in
      *$'\n'"$home"$'\n'*) continue ;;
    esac
    seen+="$home"$'\n'
    CS_HOME="$home" "$ROOT/bin/cs-procevent.sh" retire-home >/dev/null 2>&1 || true
  done
  cs_test_cleanup
}
trap when_teardown EXIT

new_home() { mkdir -p "$1/state"; WHEN_HOMES+=("$1"); }

wake_payloads() { awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null; }

first_result() {
  local g
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] || continue
    printf '%s\n' "$g"
    return 0
  done
  return 1
}

wait_for_result() {
  local n=${3:-150}
  for _ in $(seq 1 "$n"); do
    first_result "$1" "$2" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

wait_for_file() {
  local n=${2:-150}
  for _ in $(seq 1 "$n"); do [ -e "$1" ] && return 0; sleep 0.1; done
  return 1
}

COND="$TMP/cond.sh"
cat > "$COND" <<'SH'
#!/usr/bin/env bash
trigger=$1
counter=$2
echo x >> "$counter"
[ -e "$trigger" ]
SH
chmod +x "$COND"

ACT="$TMP/act.sh"
cat > "$ACT" <<'SH'
#!/usr/bin/env bash
log=$1
exit_code=${2:-0}
echo invoked >> "$log"
echo "action ran against $log"
exit "$exit_code"
SH
chmod +x "$ACT"

count_lines() { [ -e "$1" ] && grep -c . "$1" || echo 0; }

H="$TMP/h-arm"; new_home "$H"
out=$(when "$H" arm arm-test --interval 0.1 \
  --condition "$COND" "$TMP/never" "$TMP/arm-count" \
  --action "$ACT" "$TMP/arm-act")
assert_contains "$out" "armed: when-arm-test" "arm reports the canonical source id"
assert_present "$H/state/when/when-arm-test.spec" "arm writes the private spec"
assert_present "$H/state/when/when-arm-test.trust" "arm writes the trust binding"
assert_present "$H/state/procevent/when-arm-test.source" "arm registers the process-event source"
if when "$H" arm arm-test --condition true --action true 2>"$TMP/dup.err"; then
  fail "re-arming an existing watch must be refused"
fi
assert_grep "already exists" "$TMP/dup.err" "the duplicate refusal names the leftover state"
when "$H" retire arm-test >/dev/null
assert_absent "$H/state/when/when-arm-test.spec" "retire removes the spec"
pass "arm binds, refuses duplicates, and retire cleans up"

H="$TMP/h-fire"; new_home "$H"
TRIG="$TMP/fire-trigger"
ACTLOG="$TMP/fire-act"
when "$H" arm fire --interval 0.1 --stable 2 \
  --condition "$COND" "$TRIG" "$TMP/fire-count" \
  --action "$ACT" "$ACTLOG" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_file "$TMP/fire-count" || fail "the condition was never polled"
: > "$TRIG"
wait_for_result "$H" when-fire || fail "no outcome was captured after the condition held"
RESULT=$(first_result "$H" when-fire)
assert_grep 'status: fired' "$RESULT" "the outcome records a fired action"
when "$H" terminal "$RESULT" || fail "a fired outcome must be terminal"
for _ in $(seq 1 100); do
  [ ! -e "$H/state/procevent/when-fire.source" ] && break
  sleep 0.1
done
assert_absent "$H/state/procevent/when-fire.source" "a fired watch retires its registration"
pe "$H" reconcile >/dev/null
sleep 0.5
assert_contains "$(count_lines "$ACTLOG")" 1 "the action ran exactly once"
payload=$(wake_payloads "$H")
assert_contains "$payload" "procevent when when-fire 1" "the outcome wake reached the durable queue"
pass "a stable true fires the action exactly once and wakes with the outcome"

H="$TMP/h-mutated"; new_home "$H"
MUTLOG="$TMP/mutated-act"
when "$H" arm mutated --interval 0.1 --stable 1 \
  --condition true \
  --action "$ACT" "$MUTLOG" >/dev/null
echo '# mutation' >> "$ACT"
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-mutated || fail "no outcome for mutated action binding"
RESULT=$(first_result "$H" when-mutated)
assert_grep 'status: rejected' "$RESULT" "a mutated action executable is refused"
assert_absent "$MUTLOG" "a mutated action never runs"
pass "a mutated action executable is refused before firing"

printf 'all cs-procevent-when tests passed\n'
