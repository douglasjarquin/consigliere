#!/usr/bin/env bash
# cs-marker-lib.sh - the from-consigliere request marker.
#
# When the MAIN consigliere relays a work request to one of its CAPOS,
# bin/cs-send.sh prepends this marker to the message text. A capo is itself a
# consigliere running in its own home, so without a marker it treats every
# incoming line as if its boss typed it and answers CONVERSATIONALLY in its own
# chat. But the main consigliere never reads a capo's chat: the only
# main<-capo wakeup channel is the status file (charter escalation), optionally
# pointing to a doc for detail. A detailed chat-only reply therefore strands,
# unseen.
#
# The marker lets the capo tell its supervisor's request apart from a message
# the boss typed directly into its pane:
#
#   - marked   -> a from-consigliere request. Do the work, then respond via the
#                 STATUS/ESCALATION path so it surfaces to the main consigliere
#                 via the watcher signal. It MUST NOT respond only in chat.
#   - unmarked -> the boss typing directly. Stay conversational: authoritative
#                 boss intervention.
#
# This contract lives in the generated capo charter (bin/cs-brief.sh) so it
# travels with the live capo, and is summarized in AGENTS.md.
#
# Distinct from the afk daemon marker, on purpose.
# Both terminal-safe markers use U+2063 INVISIBLE SEPARATOR because it has no
# normal keyboard keystroke but travels as UTF-8 text rather than a terminal
# control byte. The away-mode marker is a BARE leading U+2063; this marker
# begins with its human-readable label and places U+2063 after it, so the two
# cannot conflate. The original ASCII 0x1f separator did not survive terminal
# input faithfully (upstream firstmate incident, herdr 0.7.3: the composer
# stripped it, delivering an unmarked message); U+2063 is the verified fix.
#
# Sourced by bin/cs-send.sh, bin/cs-brief.sh, and the tests. No side effects on
# source. set -u / set -e safe.

# The label field: human-readable, greppable, and distinctive enough that the
# boss would not type it by hand. This is the part the capo's LLM reads.
CS_FROMCONS_LABEL='[cs-from-consigliere]'

# The full marker cs-send prepends to a from-consigliere request: the label,
# then U+2063 INVISIBLE SEPARATOR (UTF-8 e2 81 a3). The request text follows.
CS_FROMCONS_SEPARATOR=$'\xE2\x81\xA3'
CS_FROMCONS_MARK="${CS_FROMCONS_LABEL}${CS_FROMCONS_SEPARATOR}"

# The away-mode daemon injection marker: a BARE leading U+2063. cs-daemon.sh
# owns injection; the constant lives here so the two markers share one
# definition site and cannot conflate.
# shellcheck disable=SC2034 # consumed by cs-daemon.sh and the afk skill
CS_INJECT_MARK=$'\xE2\x81\xA3'

# cs_message_from_consigliere: 0 (true) if <message> carries the
# from-consigliere marker - it begins with the label immediately followed by
# U+2063 - and 1 otherwise. U+2063 has no normal keyboard keystroke, so
# boss-typed input, even when it starts with the visible label text alone, is
# never matched.
cs_message_from_consigliere() {  # <message>
  case "$1" in
    "$CS_FROMCONS_MARK"*) return 0 ;;
  esac
  return 1
}

# cs_message_mark_from_consigliere: assign <message> with exactly one leading
# from-consigliere marker. This is the single owner of marker transformation,
# so callers cannot drift on separator bytes or double-prefix an
# already-marked message.
cs_message_mark_from_consigliere() {  # <message> <result-var>
  local message=${1-} result_var=${2-} transformed
  [ -n "$result_var" ] || return 2
  if cs_message_from_consigliere "$1"; then
    transformed=$message
  else
    transformed="${CS_FROMCONS_MARK}${message}"
  fi
  printf -v "$result_var" '%s' "$transformed"
}
