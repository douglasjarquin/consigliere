#!/bin/sh
# Protocol-faithful stand-in for `codex exec --json`.
set -eu
echo '{"type":"thread.started","thread_id":"codex-fixture"}'
echo '{"type":"turn.started"}'
echo '{"type":"agent_message","text":"working"}'
echo '{"type":"turn.completed"}'
echo '{"type":"thread.completed"}'
exit 0
