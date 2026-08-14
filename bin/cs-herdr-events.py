#!/usr/bin/env python3
"""Raw AF_UNIX subscriber for herdr's native push event stream.

This is the WIRE TRANSPORT half of the herdr push-escalation path
(bin/cs-watch.sh cs_watch_wait_transition). It deliberately does NOT know
consigliere's supervision policy: it opens ONE connection to a herdr session's
control socket, subscribes to the kinds below for the given panes, and prints
one projected line per event to stdout, flushing each so the bash caller can
react sub-second. The bash side normalizes each line, applies the single-owner
policy table (bin/cs-watch.sh), decides when to stop, and kills this reader.

Subscribed kinds, one request each per pane (only the two kinds carrying a
`pane_id` in herdr's schema are actually pane-scoped server-side; see
docs/herdr.md, "Which subscription kinds are pane-scoped"):
  pane.agent_status_changed  subscribed TWICE, each filtered server-side: once
                             to agent_status=blocked and once to
                             agent_status=working. `blocked` is the wake edge
                             (herdr's native manifests already classify a
                             claude/codex permission prompt as this state, so
                             no pattern hunting is needed - docs/herdr.md,
                             "Blocked detection covers claude/codex permission
                             prompts natively"). `working` is the edge that
                             CLEARS the bash side's per-pane escalation dedupe
                             marker (bin/cs-watch.sh cs_transition_apply,
                             absorb), and it must stay on the wire: the poll
                             pass and the reconnect level-reconcile only sample
                             pane state once per poll cycle, so a working
                             window that opens and closes inside one drain
                             window (back-to-back permission prompts) is
                             observable ONLY as a pushed edge. `idle`/`done`
                             stay filtered off the wire: both map to `defer`
                             in cs_transition_policy, a pure no-op on the
                             fast path.
  pane.exited                the pane's process ended - a soldier that is gone
                             rather than quiet, which polling could only infer
                             from a later "pane not found"
  pane.agent_detected        an agent appeared in the pane, so a relaunch is a
                             fact instead of an inference; UNFILTERED, since
                             the kind takes no filter. The DELIVERED payload
                             (`EventData::PaneAgentDetected`, herdr source
                             src/api/schema/events.rs - a different enum from
                             the `Subscription` and `EventMatch` enums in the
                             same file) carries pane_id, workspace_id, an
                             optional agent, a `released` flag, and an
                             optional `final_status`, and NO `agent_status`.
                             So field 4 below is always empty for this kind,
                             cs_transition_policy takes its `fallback` arm on
                             an empty status, and the agent-detected line is
                             inert on the fast path today.
  pane.output_matched        the pane rendered text matching a requested
                             pattern (see CS_HERDR_EVENT_PATTERNS)

Patterns for pane.output_matched come from the CS_HERDR_EVENT_PATTERNS env var
as `name=regex` pairs separated by newlines. Absent, no output subscription is
requested. A pattern the server rejects fails the whole subscribe (exit 3) so a
typo is loud rather than a subscription that silently never fires.

Wire protocol (verified live: herdr 0.7.5, protocol 17, newline-delimited JSON;
the agent_status filter re-verified live at herdr 0.8.0, protocol 19, docs/herdr.md.
Every kind below was confirmed to return subscription_started against a real
pane; pane.output_changed is NOT subscribable and the server names the accepted
set in its rejection):
  request : {"id","method":"events.subscribe","params":{"subscriptions":[
             {"type":"pane.agent_status_changed","pane_id":P,"agent_status":"blocked"},
             {"type":"pane.agent_status_changed","pane_id":P,"agent_status":"working"},
             {"type":"pane.exited","pane_id":P},
             {"type":"pane.agent_detected","pane_id":P},
             {"type":"pane.output_matched","pane_id":P,"source":"recent",
              "match":{"type":"regex","value":RE}}, ...]}}\n
  ack     : {"id",...,"result":{"type":"subscription_started"}}\n
  stream  : {"event":<kind>,"data":{"pane_id","workspace_id",...}}\n

`source` is REQUIRED on pane.output_matched; omitting it is an invalid_request.

Usage: cs-herdr-events.py <socket_path> <timeout_seconds> <pane_id> [<pane_id> ...]

Output (one line per event, TAB-separated, a raw projection - NOT the final
normalized record). Field 1 is the event kind, so a consumer never has to infer
which subscription produced a line:
  @subscribed
  status\t<pane_id>\t<workspace_id>\t<agent_status>\t<agent>
  exited\t<pane_id>\t<workspace_id>\t<exit_status>\t
                             (`EventData::PaneExited` carries only pane_id and
                             workspace_id, so field 4 is empty in practice;
                             the bash `exited` branch ignores it)
  agent-detected\t<pane_id>\t<workspace_id>\t<agent_status>\t<agent>
                             (no `agent_status` in the delivered payload, so
                             field 4 is empty in practice - see above)
  output\t<pane_id>\t<workspace_id>\t<pattern_name>\t<matched_line>

Exit status:
  0  streamed until the timeout elapsed with no error - a clean bounded wait;
     the caller treats this as "no fast escalation, poll cadence preserved".
  2  bad arguments, could not connect, or could not send the subscribe request.
  3  the subscribe request did not return a subscription_started ack.
  4  the server closed the stream early or a receive operation failed.
A non-zero exit tells the bash caller to fall back to plain polling for this
cycle (the permanent fail-closed backstop), never to go silent.
"""
import json
import os
import socket
import sys
import time

CONNECT_TIMEOUT = 5.0
ACK_TIMEOUT = 5.0
RECV_CHUNK = 65536


def _read_line(sock, buf, deadline):
    """Read one newline-terminated chunk from sock, honoring an absolute
    monotonic deadline. Returns (line_bytes_or_None, buf, outcome), where
    outcome is line, timeout, closed, or error."""
    while b"\n" not in buf:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None, buf, "timeout"
        sock.settimeout(remaining)
        try:
            chunk = sock.recv(RECV_CHUNK)
        except socket.timeout:
            return None, buf, "timeout"
        except OSError:
            return None, buf, "error"
        if not chunk:
            return None, buf, "closed"
        buf += chunk
    line, buf = buf.split(b"\n", 1)
    return line, buf, "line"


# Event name -> the stable kind token this reader prints as field 1. A kind the
# bash side does not know is ignored there, so adding one here is safe.
_KINDS = {
    "pane.agent_status_changed": "status",
    "pane.exited": "exited",
    "pane.agent_detected": "agent-detected",
    "pane.output_matched": "output",
}


def _patterns():
    """[(name, regex)] from CS_HERDR_EVENT_PATTERNS `name=regex` lines."""
    raw = os.environ.get("CS_HERDR_EVENT_PATTERNS", "")
    out = []
    for line in raw.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        name, regex = line.split("=", 1)
        name, regex = name.strip(), regex.strip()
        if name and regex:
            out.append((name, regex))
    return out


def _pattern_name(patterns, data):
    """Best-effort label for which requested pattern matched. The server echoes
    the matcher back when it can; otherwise a single configured pattern is
    unambiguous, and more than one falls back to a generic label rather than
    guessing wrong."""
    echoed = data.get("match") or data.get("pattern")
    if isinstance(echoed, dict):
        echoed = echoed.get("value")
    if echoed:
        for name, regex in patterns:
            if regex == echoed:
                return name
    if len(patterns) == 1:
        return patterns[0][0]
    return "output"


def _clean(value):
    return str(value).replace("\t", " ").replace("\r", " ").replace("\n", " ")


def main(argv):
    if len(argv) < 4:
        return 2
    sock_path = argv[1]
    try:
        timeout = float(argv[2])
    except ValueError:
        return 2
    panes = argv[3:]
    if not panes or timeout <= 0:
        return 2

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(CONNECT_TIMEOUT)
        sock.connect(sock_path)
    except OSError:
        return 2

    patterns = _patterns()
    subscriptions = []
    for pane in panes:
        for status in ("blocked", "working"):
            subscriptions.append(
                {
                    "type": "pane.agent_status_changed",
                    "pane_id": pane,
                    "agent_status": status,
                }
            )
        subscriptions.append({"type": "pane.exited", "pane_id": pane})
        subscriptions.append({"type": "pane.agent_detected", "pane_id": pane})
        for name, regex in patterns:
            subscriptions.append(
                {
                    "type": "pane.output_matched",
                    "pane_id": pane,
                    # `source` is required by the server; recent covers output
                    # that has already scrolled past the visible viewport.
                    "source": "recent",
                    "match": {"type": "regex", "value": regex},
                }
            )
    request = {
        "id": "cs-eventwait",
        "method": "events.subscribe",
        "params": {"subscriptions": subscriptions},
    }
    try:
        sock.sendall((json.dumps(request) + "\n").encode("utf-8"))
    except OSError:
        return 2

    start = time.monotonic()
    deadline = start + timeout
    buf = b""

    # Bounded wait for the subscription_started ack (its own short budget, but
    # never past the overall deadline).
    ack_deadline = min(deadline, start + ACK_TIMEOUT)
    line, buf, outcome = _read_line(sock, buf, ack_deadline)
    if line is None:
        return 2
    try:
        ack = json.loads(line.decode("utf-8", "replace"))
    except ValueError:
        return 3
    result = ack.get("result") or {}
    if result.get("type") != "subscription_started":
        return 3

    sys.stdout.write("@subscribed\n")
    sys.stdout.flush()

    # Stream projected events until the deadline or the server closes.
    while True:
        line, buf, outcome = _read_line(sock, buf, deadline)
        if line is None:
            return 0 if outcome == "timeout" else 4
        try:
            message = json.loads(line.decode("utf-8", "replace"))
        except ValueError:
            continue
        kind = _KINDS.get(message.get("event"))
        if kind is None:
            continue
        data = message.get("data") or {}
        if kind == "exited":
            third, fourth = data.get("exit_status"), ""
            if third is None:
                third = data.get("status") or ""
        elif kind == "output":
            third = _pattern_name(patterns, data)
            fourth = data.get("line") or data.get("matched") or ""
        else:
            third, fourth = data.get("agent_status") or "", data.get("agent") or ""
        fields = (
            kind,
            _clean(data.get("pane_id") or ""),
            _clean(data.get("workspace_id") or ""),
            _clean(third),
            _clean(fourth),
        )
        sys.stdout.write("\t".join(fields) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except BrokenPipeError:
        # The bash caller stopped reading (found its actionable edge and killed
        # us). That is a normal, successful end of the wait.
        sys.exit(0)
    except KeyboardInterrupt:
        sys.exit(0)
