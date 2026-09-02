# shellcheck shell=bash
# cs-line-cap-lib.sh - shared per-line cap for agent-facing digest lines.
# Usage: . bin/cs-line-cap-lib.sh; cs_cap_line "<line>" [<max>]
#
# ONE OWNER for the bounded-line shape both digests use. The wake digest's
# OPEN DECISIONS section (bin/cs-wake-drain.sh) and the session-start digest's
# per-task status tails (bin/cs-session-start.sh) render the same kind of
# content - an agent-written status line, which AGENTS.md section 7 treats as a
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
#
# <max> is a hard ceiling, never an approximation: a cut line is never longer
# than <max> characters even when <max> is smaller than the marker itself. At
# that size no content can survive alongside a disclosure, so the marker is what
# is kept, cut to <max> in turn - the result still reads as truncated rather
# than passing a fragment of content off as a whole line. A <max> of zero or
# less yields the empty string.
cs_cap_line_var() {
  local LC_ALL=C
  local line=$1 max=${2:-$CS_LINE_CAP_DEFAULT} keep bytes suffix=$CS_LINE_CAP_SUFFIX
  local offset=0 characters=0 keep_bytes=0 byte width next1 next2 next3
  [ "$max" -ge 0 ] || max=0
  keep=$((max - ${#suffix}))
  if [ "$keep" -lt 0 ]; then
    suffix=${suffix:0:max}
    keep=0
  fi
  bytes=${#line}
  while [ "$offset" -lt "$bytes" ]; do
    printf -v byte '%d' "'${line:$offset:1}"
    [ "$byte" -ge 0 ] || byte=$((byte + 256))
    width=1
    if ((byte >= 194 && byte <= 223 && offset + 1 < bytes)); then
      printf -v next1 '%d' "'${line:$((offset + 1)):1}"
      [ "$next1" -ge 0 ] || next1=$((next1 + 256))
      if ((next1 >= 128 && next1 <= 191)); then
        width=2
      fi
    elif ((byte >= 224 && byte <= 239 && offset + 2 < bytes)); then
      printf -v next1 '%d' "'${line:$((offset + 1)):1}"
      printf -v next2 '%d' "'${line:$((offset + 2)):1}"
      [ "$next1" -ge 0 ] || next1=$((next1 + 256))
      [ "$next2" -ge 0 ] || next2=$((next2 + 256))
      if ((next2 >= 128 && next2 <= 191)); then
        if ((byte == 224 && next1 >= 160 && next1 <= 191)); then
          width=3
        elif ((byte == 237 && next1 >= 128 && next1 <= 159)); then
          width=3
        elif ((byte != 224 && byte != 237 && next1 >= 128 && next1 <= 191)); then
          width=3
        fi
      fi
    elif ((byte >= 240 && byte <= 244 && offset + 3 < bytes)); then
      printf -v next1 '%d' "'${line:$((offset + 1)):1}"
      printf -v next2 '%d' "'${line:$((offset + 2)):1}"
      printf -v next3 '%d' "'${line:$((offset + 3)):1}"
      [ "$next1" -ge 0 ] || next1=$((next1 + 256))
      [ "$next2" -ge 0 ] || next2=$((next2 + 256))
      [ "$next3" -ge 0 ] || next3=$((next3 + 256))
      if ((next2 >= 128 && next2 <= 191 && next3 >= 128 && next3 <= 191)); then
        if ((byte == 240 && next1 >= 144 && next1 <= 191)); then
          width=4
        elif ((byte >= 241 && byte <= 243 && next1 >= 128 && next1 <= 191)); then
          width=4
        elif ((byte == 244 && next1 >= 128 && next1 <= 143)); then
          width=4
        fi
      fi
    fi
    offset=$((offset + width))
    characters=$((characters + 1))
    [ "$characters" -ne "$keep" ] || keep_bytes=$offset
    if [ "$characters" -gt "$max" ]; then
      CS_LINE_CAP_LINE="${line:0:$keep_bytes}$suffix"
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
