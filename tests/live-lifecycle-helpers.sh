#!/usr/bin/env bash
# tests/live-lifecycle-helpers.sh - shared waits for the two LIVE lifecycle twins
# (cs-lifecycle-live.test.sh for codex, cs-lifecycle-claude-live.test.sh for
# claude), which drive real agents through the same sequence and differ only in
# the harness under them.
#
# It lives here rather than in tests/lib.sh because it needs bin/cs-herdr-lib.sh's
# status policy, which only the live suites source, and rather than once per suite
# because the twins had already drifted: the claude lane learned to wait on the
# corroborated busy state while the codex lane still named a literal status, which
# is how that lane came to burn 660s of every run on waits that asserted nothing.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# wait_not_busy <pane> <secs> - wait until the pane is not mid-turn. rc=1 on timeout.
#
# Deliberately NOT `agent wait --until idle`: a finished turn can report native
# `done`, which docs/herdr.md maps to `done` and not to `idle`, so the strict wait
# times out against a perfectly healthy agent (observed 2026-08-11, claude 2.1.227
# and codex-cli 0.147.0). The corroborated busy state is also what every
# consigliere caller actually acts on, so waiting on it tests the real contract.
#
# Only `idle` and `done` are settled. The other two answers are NOT rests and an
# earlier version of this helper treated them as one, which is a real hazard for
# the caller that steers next:
#   unknown - the pane's agent could not be READ this poll, which under load is a
#             transient failure rather than a resting agent. Returning on it hands
#             the caller a pane that may not be ready to accept input, and a steer
#             into a not-ready composer comes back as an unconfirmed submit rather
#             than as anything that names this cause. So keep waiting.
#   blocked - the agent is waiting on a human (a folder-trust dialog, a permission
#             prompt). That is terminal for a wait, not transient, so return
#             immediately instead of burning the whole budget on it.
wait_not_busy() { # <pane> <secs>
  local waited=0 state
  while [ "$waited" -lt "$2" ]; do
    state=$(cs_herdr_agent_busy_state "$1")
    case "$state" in
      idle|done) return 0 ;;
      blocked)   return 1 ;;
    esac
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}
