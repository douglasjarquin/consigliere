#!/usr/bin/env python3
"""Minimal herdr-shaped API server that HONORS the agent_status subscription
filter, so the real bin/cs-herdr-events.py + bin/cs-watch.sh push path can be
exercised end-to-end without a herdr binary.

argv: <sock> <capture.json> <pane_id> <status>...
It attempts every <status> edge for <pane_id> and only puts on the wire those a
subscription actually asked for - exactly what herdr 0.8.0's server-side filter
does. Suppressed/delivered edges are logged to <capture.json>.log.
"""
import json, os, socket, sys, time

sock_path, capture_path, pane = sys.argv[1], sys.argv[2], sys.argv[3]
attempts = sys.argv[4:]

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
req = json.loads(line)
open(capture_path, "w").write(json.dumps(req, indent=2) + "\n")

wanted = {
    s.get("agent_status")
    for s in req["params"]["subscriptions"]
    if s.get("type") == "pane.agent_status_changed" and s.get("pane_id") == pane
}
conn.sendall(b'{"id":"cs-eventwait","result":{"type":"subscription_started"}}\n')

log = open(capture_path + ".log", "w")
log.write("server-side agent_status filters requested for %s: %s\n"
          % (pane, sorted(x for x in wanted if x)))
for st in attempts:
    if st in wanted:
        conn.sendall((json.dumps({
            "event": "pane.agent_status_changed",
            "data": {"pane_id": pane, "workspace_id": "ws-1",
                     "agent_status": st, "agent": "claude"},
        }) + "\n").encode())
        log.write("  DELIVERED  agent_status=%s\n" % st)
    else:
        log.write("  SUPPRESSED agent_status=%s (no subscription asked for it)\n" % st)
    log.flush()
    time.sleep(0.1)
# Hold the connection open past the reader's own deadline: a server that
# hangs up early is a different case (reader exit 4) than a quiet stream.
time.sleep(float(os.environ.get("HOLD_SECS", "8")))
conn.close()
srv.close()
