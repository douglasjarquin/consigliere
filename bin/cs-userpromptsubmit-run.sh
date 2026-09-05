#!/usr/bin/env bash
# cs-userpromptsubmit-run.sh - drain the wake queue before EVERY user turn in a
# primary session, so a queued blocked:/needs-decision: signal reaches context
# on the very next turn regardless of what that turn looks like.
#
# AGENTS.md section 7 previously required draining "before ... any
# wake-handling turn". An ordinary conversational reply to the boss does not
# classify as one, so a capo's blocked:/needs-decision: status line could sit
# unnoticed in the wake queue through several routine chat turns before
# consigliere ever ran a drain (transcript-verified gap; see
# docs/supervision.md). This hook removes the judgment call the same way
# bin/cs-sessionstart-run.sh removes it for session open (docs/claude.md's
# session-open section: hook stdout is delivered into context before the
# model's first turn): it runs bin/cs-wake-drain.sh - already cheap and silent
# on an empty queue (see that script's header) - on every UserPromptSubmit, so
# the digest never depends on the agent recognizing a turn as wake-handling.
#
# Every path exits 0: a UserPromptSubmit hook that fails would block the
# boss's message from ever reaching the model, which is worse than a missed
# drain.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A made gate agent must never drain the fleet queue for the home it is
# validating (mirrors bin/cs-sessionstart-run.sh's own guard).
[ -z "${NO_MISTAKES_GATE:-}" ] || exit 0

PAYLOAD=$(cat 2>/dev/null || true)

# shellcheck source=bin/cs-hook-host-lib.sh
. "$SCRIPT_DIR/cs-hook-host-lib.sh"
cs_hook_payload_is_foreign_host "$PAYLOAD" && exit 0

# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
CS_LAYOUT_GATE_SKIP=1
cs_resolve_root || exit 0
CS_LAYOUT_GATE_SKIP=

# shellcheck source=bin/cs-primary-scope-lib.sh
. "$SCRIPT_DIR/cs-primary-scope-lib.sh"
cs_primary_scope_matches "$CS_ROOT" "$STATE" || exit 0

"$SCRIPT_DIR/cs-wake-drain.sh"
exit 0
