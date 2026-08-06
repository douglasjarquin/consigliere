# shellcheck shell=bash
# cs-line-cap-lib.sh - shared per-line cap for agent-facing digest lines.
# Usage: . bin/cs-line-cap-lib.sh; cs_cap_line "<line>" [<max>]
#
# ONE OWNER for the bounded-line shape both digests use. The wake digest's
# OPEN DECISIONS section (bin/cs-wake-drain.sh) and the session-start digest's
# per-task status tails (bin/cs-session-start.sh) render the same kind of
# content - an agent-written status line, which AGENTS.md section 8 treats as a
# wake EVENT rather than current state - into a size-bounded view. An agent
# reading both must recognize one truncation marker, and the two caps must not
# drift apart, so the cut and its marker live here.
#
# Callers keep their own composite policy: cs-wake-drain.sh still owns its
# open-decisions count cap and omission disclosure, and cs-session-start.sh
# still owns how many tail lines it prints per task. This file owns only the
# per-line cut.
#
# The cap counts complete UTF-8 byte sequences itself, so installed locale names
# and the inherited locale cannot change the measurement or slice. A plain-ASCII
# line is bounded to the same number of bytes, and a multibyte character is never
# cut in half into an invalid sequence.
# Truncation stays recoverable because the session-start digest prints each
# task's full status log path, while every OPEN DECISIONS entry begins with the
# task id that identifies its durable state/<id>.status source.

CS_LINE_CAP_DEFAULT=220
CS_LINE_CAP_SUFFIX=' [truncated]'

# cs_cap_line_var <line> [<max>]: put <line> in CS_LINE_CAP_LINE, cut to <max>
# characters with CS_LINE_CAP_SUFFIX in place of the tail when it is longer. A
# line at or under the cap is kept unchanged, marker and all bytes intact.
# This is the rule itself. It assigns rather than prints so a caller composing
# a larger section never pays a command substitution per item on a path that
# runs at the top of every wake-handling turn.
cs_cap_line_var() {
  local LC_ALL=C
  local line=$1 max=${2:-$CS_LINE_CAP_DEFAULT} keep bytes
  local offset=0 characters=0 keep_bytes=0 byte width
  keep=$((max - ${#CS_LINE_CAP_SUFFIX}))
  [ "$keep" -ge 0 ] || keep=0
  bytes=${#line}
  while [ "$offset" -lt "$bytes" ]; do
    printf -v byte '%d' "'${line:$offset:1}"
    [ "$byte" -ge 0 ] || byte=$((byte + 256))
    if [ "$byte" -lt 128 ]; then
      width=1
    elif [ "$byte" -lt 224 ]; then
      width=2
    elif [ "$byte" -lt 240 ]; then
      width=3
    else
      width=4
    fi
    offset=$((offset + width))
    characters=$((characters + 1))
    [ "$characters" -ne "$keep" ] || keep_bytes=$offset
    if [ "$characters" -gt "$max" ]; then
      CS_LINE_CAP_LINE="${line:0:$keep_bytes}$CS_LINE_CAP_SUFFIX"
      return 0
    fi
  done
  CS_LINE_CAP_LINE=$line
}

# cs_cap_line <line> [<max>]: the same cut, printed on stdout, for a caller that
# is streaming lines rather than accumulating them.
cs_cap_line() {
  cs_cap_line_var "$@"
  printf '%s\n' "$CS_LINE_CAP_LINE"
}
