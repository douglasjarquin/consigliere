#!/usr/bin/env bash
# tests/cs-detach.test.sh - bin/cs-detach.py starts a command in its OWN session,
# so it outlives teardown of the launching process group.
#
# This is the property `nohup ... & disown` does NOT have, and the whole reason
# the persistent monitor churned: a checkpoint always runs inside a tool call's
# process group. The test kills a launcher group directly and asserts which child
# keeps running.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DETACH="$ROOT/bin/cs-detach.py"

# Local, so this suite needs nothing from the watcher fixtures.
wait_until() {  # <limit-ticks> <cmd...>
  local limit=$1 i=0; shift
  while [ "$i" -lt "$limit" ]; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
TMP=$(cs_test_tmproot cs-detach)
mkdir -p "$TMP"
command -v python3 >/dev/null 2>&1 || { echo "ok - skipped: python3 absent"; exit 0; }

# --- argument handling -------------------------------------------------------
set +e
out=$(python3 "$DETACH" 2>&1); rc=$?
set -e
expect_code 2 "$rc" "no command should exit 2"
assert_contains "$out" "usage:" "a bare invocation prints usage"
pass "cs-detach rejects a missing command with usage"

# --- the child lands in its own session --------------------------------------
beat="$TMP/beat"
pid=$(python3 "$DETACH" --stdout "$TMP/child.log" -- \
  bash -c "for i in \$(seq 1 60); do echo tick >> $beat; sleep 1; done")
[ -n "$pid" ] || fail "cs-detach printed no pid"
wait_until 40 test -s "$beat" || { kill "$pid" 2>/dev/null; fail "the detached child never ran"; }
child_pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d " ")
own_pgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d " ")
[ -n "$child_pgid" ] || fail "could not read the child process group"
[ "$child_pgid" != "$own_pgid" ] \
  || fail "the child shares this process group ($child_pgid); a group kill would reach it"
kill -KILL "$pid" 2>/dev/null || true
pass "a detached child runs in its own process group, not the launcher's"

# --- it survives a group kill that a nohup sibling does not ------------------
# An inner launcher, itself detached, becomes a session leader with group G. It
# starts one child the old way (shares G) and one through the shim (own group).
# Killing G must take only the first.
inner="$TMP/inner.sh"
cat > "$inner" <<EOF
#!/usr/bin/env bash
nohup bash -c 'for i in \$(seq 1 90); do echo a >> $TMP/beat-nohup; sleep 1; done' >/dev/null 2>&1 &
disown 2>/dev/null || true
python3 "$DETACH" --stdout /dev/null -- bash -c 'for i in \$(seq 1 90); do echo b >> $TMP/beat-detach; sleep 1; done' > $TMP/pid-detach
sleep 90
EOF
chmod +x "$inner"
launcher=$(python3 "$DETACH" --stdout "$TMP/inner.log" -- "$inner")
wait_until 60 test -s "$TMP/beat-detach" || { kill "$launcher" 2>/dev/null; fail "the inner launcher never started its children"; }
wait_until 60 test -s "$TMP/beat-nohup" || { kill "$launcher" 2>/dev/null; fail "the nohup sibling never started"; }
group=$(ps -o pgid= -p "$launcher" 2>/dev/null | tr -d " ")
[ -n "$group" ] && [ "$group" != "$own_pgid" ] || fail "refusing to kill this test's own process group"
nohup_before=$(wc -l < "$TMP/beat-nohup" | tr -d " ")
kill -KILL -- -"$group" 2>/dev/null || true
sleep 3
detach_pid=$(cat "$TMP/pid-detach" 2>/dev/null || true)
nohup_after=$(wc -l < "$TMP/beat-nohup" | tr -d " ")
detach_mid=$(wc -l < "$TMP/beat-detach" | tr -d " ")
sleep 3
detach_after=$(wc -l < "$TMP/beat-detach" | tr -d " ")
[ "$nohup_after" -le $((nohup_before + 1)) ] \
  || fail "the nohup sibling survived the group kill ($nohup_before -> $nohup_after); the test proves nothing"
[ "$detach_after" -gt "$detach_mid" ] \
  || fail "the detached child stopped counting after the group kill ($detach_mid -> $detach_after)"
[ -n "$detach_pid" ] && kill -KILL "$detach_pid" 2>/dev/null || true
pass "a detached child survives a group kill that stops its nohup sibling"

pass "cs-detach session isolation"
