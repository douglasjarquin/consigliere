#!/usr/bin/env python3
"""Read-only capture of one live herdr pane.agent_status_changed payload.

Subscribes over the running herdr 0.8.0 server's control socket (no plugin is
linked, nothing in the user's global registry is touched) and prints the first
status event's JSON verbatim, so the real payload can be fed to
bin/cs-herdr-event-hook.sh exactly as herdr's plugin dispatcher would.
"""
import json
import socket
import sys
import time

sock_path, timeout, panes = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5.0)
s.connect(sock_path)
req = {
    "id": "live-capture",
    "method": "events.subscribe",
    "params": {"subscriptions": [
        {"type": "pane.agent_status_changed", "pane_id": p} for p in panes
    ]},
}
s.sendall((json.dumps(req) + "\n").encode())
buf = b""
deadline = time.monotonic() + timeout
while True:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        print("TIMEOUT: no status edge on the live fleet within the budget")
        sys.exit(1)
    s.settimeout(remaining)
    try:
        chunk = s.recv(65536)
    except socket.timeout:
        print("TIMEOUT: no status edge on the live fleet within the budget")
        sys.exit(1)
    if not chunk:
        print("CLOSED")
        sys.exit(2)
    buf += chunk
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        if not line.strip():
            continue
        msg = json.loads(line)
        if msg.get("result", {}).get("type") == "subscription_started":
            print("ACK: subscription_started")
            continue
        if msg.get("event") == "pane.agent_status_changed":
            print("LIVE_EVENT " + json.dumps(msg, separators=(",", ":")))
            sys.exit(0)
