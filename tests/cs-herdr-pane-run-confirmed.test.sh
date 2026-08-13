#!/usr/bin/env bash
# Behavior (portable): cs_herdr_pane_run_confirmed must be satisfiable ONLY by
# output the typed line produces when it EXECUTES. The pty renders the typed
# line the moment the bytes arrive - before, and independently of, the shell
# running it - so a match string contained in the typed spelling would confirm
# exactly the swallowed-line case the helper exists to catch (a not-yet-ready
# worktree pane shell losing an env export, docs/herdr.md "pane run").
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/cs-herdr-lib.sh
. "$ROOT/bin/cs-herdr-lib.sh"

TMP=$(cs_test_tmproot cs-herdr-pane-run-confirmed)
FAKEBIN=$(cs_fakebin "$TMP")

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "pane run")
    printf '%s\n' "${4:-}" > "$CS_FAKE_RUN"
    echo '{}'
    ;;
  "pane wait-output")
    shift 3
    match=
    while [ "$#" -gt 0 ]; do
      case "$1" in --match) match=${2:-}; shift ;; esac
      shift
    done
    printf '%s\n' "$match" > "$CS_FAKE_MATCH"
    if [ "${CS_FAKE_WAIT_FAIL:-0}" = 1 ]; then
      printf '{"error":{"code":"wait_timeout","message":"no match"}}\n' >&2
      exit 1
    fi
    printf '{"result":{"matched":true}}\n'
    ;;
  *) echo '{}' ;;
esac
SH
chmod +x "$FAKEBIN/herdr"
export PATH="$FAKEBIN:$PATH" CS_FAKE_RUN="$TMP/run" CS_FAKE_MATCH="$TMP/match"

cs_herdr_pane_run_confirmed w1:p1 ':' 1000 || fail "a matched wait-output must confirm the run"
typed=$(cat "$TMP/run")
match=$(cat "$TMP/match")
[ -n "$match" ] || fail "no --match value reached wait-output"
case "$typed" in
  *"$match"*) fail "the typed line contains the match string, so the pty's echo of the UNEXECUTED line would confirm a swallowed run: $typed" ;;
esac
# The matched string must be exactly what executing the typed line emits.
out=$(bash -c "$typed") || fail "the typed line failed to execute: $typed"
[ "$out" = "$match" ] || fail "executing the typed line emitted '$out', but wait-output was asked for '$match'"
# And in a POSIX shell pane too, since a pane runs the user's own shell.
out=$(sh -c "$typed") || fail "the typed line failed to execute under sh: $typed"
[ "$out" = "$match" ] || fail "sh executing the typed line emitted '$out', not '$match'"

CS_FAKE_WAIT_FAIL=1 cs_herdr_pane_run_confirmed w1:p1 ':' 1000 \
  && fail "an unmatched wait-output must fail the confirmation, not swallow it"

pass "pane_run_confirmed's marker is producible only by executing the typed line"
