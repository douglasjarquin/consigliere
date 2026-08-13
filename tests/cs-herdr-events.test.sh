#!/usr/bin/env bash
# Behavior (portable): bin/cs-herdr-events.py's subscribe request over herdr's
# real wire protocol (newline-delimited JSON over AF_UNIX).
#
# herdr's own detection manifests already classify a claude/codex permission
# prompt as native `agent_status: blocked` (docs/herdr.md, "Blocked detection
# covers claude/codex permission prompts natively"), and `pane.agent_status_changed`
# subscriptions accept an optional `agent_status` filter so the SERVER, not this
# reader, decides which status edges are worth a wire message
# (data/stow-synthesis-survey/report.md, S2). This suite runs a minimal real
# AF_UNIX socket server (no herdr binary needed) and asserts the actual bytes
# cs-herdr-events.py sends, so a regression that silently drops the filter (or
# widens it back to every edge) fails here instead of only in a live lab.
#
# tests/cs-watch-triage.test.sh separately covers cs_watch_wait_transition's
# BASH-side decode of whatever the reader prints; that suite fakes the reader
# entirely and never touches the real subscribe payload, so the two suites do
# not overlap.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "1..0 # skip python3 is required"; exit 0; }

READER="$ROOT/bin/cs-herdr-events.py"

# fake_server: accept exactly one connection on <sock>, capture the first
# newline-delimited request line to <capture>, ACK it, then stream <events...>
# (each already newline-free) before closing. Runs in the background so the
# reader (a real client) can connect to it; the test waits on the capture file
# rather than a fixed sleep, bounded so a hung server cannot wedge the suite.
fake_server() {  # <sock> <capture> <event>...
  local sock=$1 capture=$2
  shift 2
  # Redirected explicitly: an inherited stdout on the CALLER's command-
  # substitution pipe (`server_pid=$(fake_server ...)`) would hold that pipe's
  # write end open for as long as this background server keeps running (it
  # blocks in accept() until the reader connects), so the caller's $(...)
  # would never see EOF and would hang past its own return.
  python3 - "$sock" "$capture" "$@" > /dev/null 2>&1 <<'PY' &
import socket, sys
sock_path, capture_path = sys.argv[1], sys.argv[2]
events = sys.argv[3:]
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock_path)
srv.listen(1)
conn, _ = srv.accept()
buf = b""
while b"\n" not in buf:
    chunk = conn.recv(65536)
    if not chunk:
        break
    buf += chunk
line, _, _ = buf.partition(b"\n")
with open(capture_path, "wb") as f:
    f.write(line + b"\n")
conn.sendall(b'{"id":"cs-eventwait","result":{"type":"subscription_started"}}\n')
for ev in events:
    conn.sendall((ev + "\n").encode("utf-8"))
conn.close()
srv.close()
PY
  echo $!
}

wait_for_file() {  # <path> <max-tenths-of-a-second> - non-empty REGULAR file
  local path=$1 n=$2 i=0
  while [ ! -s "$path" ]; do
    i=$((i + 1))
    [ "$i" -le "$n" ] || return 1
    sleep 0.1
  done
  return 0
}

wait_for_socket() {  # <path> <max-tenths-of-a-second> - a bound AF_UNIX socket
  # A socket special file reports size 0 (`test -s` is always false for it),
  # so this checks existence only, unlike wait_for_file above.
  local path=$1 n=$2 i=0
  while [ ! -e "$path" ]; do
    i=$((i + 1))
    [ "$i" -le "$n" ] || return 1
    sleep 0.1
  done
  return 0
}

# --- subscribe request carries the agent_status:blocked filter --------------

test_status_subscription_is_filtered_to_blocked() {
  local dir sock capture server_pid out req
  dir=$(cs_test_tmproot cs-herdr-events)
  sock="$dir/fake.sock"
  capture="$dir/request.json"

  server_pid=$(fake_server "$sock" "$capture" \
    '{"event":"pane.agent_status_changed","data":{"pane_id":"w1:p1","workspace_id":"w1","agent_status":"blocked","agent":"claude"}}')
  wait_for_socket "$sock" 30 || { kill "$server_pid" 2>/dev/null || true; fail "fake server never bound its socket"; }

  out=$(python3 "$READER" "$sock" 2 w1:p1 2>/dev/null)
  wait "$server_pid" 2>/dev/null || true

  wait_for_file "$capture" 10 || fail "fake server never captured a request"
  req=$(cat "$capture")

  # The status subscription for the pane must carry agent_status:blocked -
  # the server-side filter this suite exists to pin. jq -e fails (and this
  # test with it) if the entry, or the filter field on it, is missing.
  printf '%s' "$req" | jq -e '
    .params.subscriptions
    | map(select(.type == "pane.agent_status_changed" and .pane_id == "w1:p1"))
    | length == 1 and .[0].agent_status == "blocked"
  ' >/dev/null || fail "status subscription missing agent_status:blocked filter: $req"

  # pane.exited and pane.agent_detected stay unfiltered - only the status kind
  # narrows, never the other two kinds this reader also relies on.
  printf '%s' "$req" | jq -e '
    .params.subscriptions
    | map(select(.type == "pane.exited" and .pane_id == "w1:p1" and (has("agent_status") | not)))
    | length == 1
  ' >/dev/null || fail "pane.exited subscription changed shape: $req"
  printf '%s' "$req" | jq -e '
    .params.subscriptions
    | map(select(.type == "pane.agent_detected" and .pane_id == "w1:p1" and (has("agent_status") | not)))
    | length == 1
  ' >/dev/null || fail "pane.agent_detected subscription changed shape: $req"

  # A filtered blocked event the server actually sends still decodes exactly
  # like the old unfiltered stream did - the filter narrows the WIRE, not the
  # projected line shape the bash side already pins.
  assert_contains "$out" "$(printf 'status\tw1:p1\tw1\tblocked\tclaude')" \
    "a server-filtered blocked event must still print the ordinary projected line"
  pass "cs-herdr-events.py subscribes to agent_status:blocked only, leaving exited/agent-detected unfiltered"
}

test_status_subscription_is_filtered_to_blocked
