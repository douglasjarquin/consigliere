#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$SCRIPT_DIR/cs-meta-lib.sh"
cs_resolve_root

ID=${1:-}
case "$ID" in
  ''|.*|*[!A-Za-z0-9._-]*) exit 0 ;;
esac

[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 0
META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || exit 0

WORKTREE=$(cs_meta_get "$META" worktree 2>/dev/null || true)
[ -n "$WORKTREE" ] && [ -d "$WORKTREE" ] && [ ! -L "$WORKTREE" ] || exit 0
[ -d "$WORKTREE/.omo" ] && [ ! -L "$WORKTREE/.omo" ] || exit 0
BOULDER="$WORKTREE/.omo/boulder.json"
[ -f "$BOULDER" ] && [ ! -L "$BOULDER" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

PLAN_REF=$(jq -er '
  (.active_work_id // empty) as $work_id
  | if ($work_id | type) == "string"
      and (.works | type) == "object"
      and (.works[$work_id].active_plan | type) == "string"
    then .works[$work_id].active_plan
    else empty
    end
' "$BOULDER" 2>/dev/null) || exit 0

case "$PLAN_REF" in
  .omo/plans/*.md) PLAN="$WORKTREE/$PLAN_REF" ;;
  "$WORKTREE"/.omo/plans/*.md) PLAN=$PLAN_REF ;;
  *) exit 0 ;;
esac
case "$PLAN_REF" in
  *..*|*//* ) exit 0 ;;
esac
[ -f "$PLAN" ] && [ ! -L "$PLAN" ] || exit 0

COUNTS=$(LC_ALL=C awk '
function fence_opening(text, s, marker, run, rest) {
  s=text
  if (substr(s, 1, 1) == " " || substr(s, 1, 1) == "\t") sub(/^[ \t]/, "", s)
  if (substr(s, 1, 1) == " " || substr(s, 1, 1) == "\t") sub(/^[ \t]/, "", s)
  if (substr(s, 1, 1) == " " || substr(s, 1, 1) == "\t") sub(/^[ \t]/, "", s)
  marker=substr(s, 1, 1)
  if (marker != "`" && marker != "~") return ""
  run=0
  while (substr(s, run + 1, 1) == marker) run++
  if (run < 3) return ""
  rest=substr(s, run + 1)
  if (marker == "`" && index(rest, "`") > 0) return ""
  return marker SUBSEP run
}
function fence_closes(text, marker, required, s, run, rest) {
  s=text
  if (substr(s, 1, 1) == " " || substr(s, 1, 1) == "\t") sub(/^[ \t]/, "", s)
  if (substr(s, 1, 1) == " " || substr(s, 1, 1) == "\t") sub(/^[ \t]/, "", s)
  if (substr(s, 1, 1) == " " || substr(s, 1, 1) == "\t") sub(/^[ \t]/, "", s)
  if (substr(s, 1, 1) != marker) return 0
  run=0
  while (substr(s, run + 1, 1) == marker) run++
  if (run < required) return 0
  rest=substr(s, run + 1)
  return rest ~ /^[ \t]*$/
}
function heading_section(text) {
  if (text ~ /^##[ \t]+TODOs([ \t]+#+)?[ \t]*$/) return "todo"
  if (text ~ /^##[ \t]+Final Verification Wave([ \t]+#+)?[ \t]*$/) return "final-wave"
  return "other"
}
function checked(text, open) {
  open=index(text, "[")
  return tolower(substr(text, open + 1, 1)) == "x"
}
{
  lines[NR]=$0
  if (fence != "") {
    split(fence, parts, SUBSEP)
    if (fence_closes($0, parts[1], parts[2])) fence=""
    next
  }
  opening=fence_opening($0)
  if (opening != "") {
    fence=opening
    next
  }
  if (heading_section($0) != "other") structured=1
}
END {
  if (structured) {
    fence=""
    section="other"
    for (i=1; i<=NR; i++) {
      line=lines[i]
      if (fence != "") {
        split(fence, parts, SUBSEP)
        if (fence_closes(line, parts[1], parts[2])) fence=""
        continue
      }
      opening=fence_opening(line)
      if (opening != "") {
        fence=opening
        continue
      }
      if (line ~ /^##?([ \t]+|$)/) {
        section=heading_section(line)
        continue
      }
      if (section == "todo" && line ~ /^- \[[ xX]\] [1-9][0-9]*[.] .+$/) {
        total++
        if (checked(line)) completed++
        else remaining++
      } else if (section == "final-wave" && line ~ /^- \[[ xX]\] [Ff][1-9][0-9]*[.] .+$/) {
        total++
        if (checked(line)) completed++
        else remaining++
      }
    }
  } else {
    fence=""
    for (i=1; i<=NR; i++) {
      line=lines[i]
      if (fence != "") {
        split(fence, parts, SUBSEP)
        if (fence_closes(line, parts[1], parts[2])) fence=""
        continue
      }
      opening=fence_opening(line)
      if (opening != "") {
        fence=opening
        continue
      }
      if (line ~ /^[-*][ \t]*\[[ \t]*[xX]?[ \t]*\][ \t]+.+$/) {
        total++
        if (checked(line)) completed++
        else remaining++
      }
    }
  }
  if (total > 0) printf "%d %d\n", remaining, total
}
' "$PLAN" 2>/dev/null) || exit 0
[ -n "$COUNTS" ] || exit 0

REMAINING=${COUNTS%% *}
TOTAL=${COUNTS#* }
case "$REMAINING" in
  ''|*[!0-9]*) exit 0 ;;
esac
case "$TOTAL" in
  ''|*[!0-9]*) exit 0 ;;
esac
PROGRESS="$REMAINING/$TOTAL"
LAST="$STATE/$ID.plan-progress"
[ ! -L "$LAST" ] || exit 0
if [ -f "$LAST" ]; then
  previous=$(sed -n '1p' "$LAST" 2>/dev/null || true)
  [ "$previous" = "$PROGRESS" ] && exit 0
fi

umask 077
TMP=$(mktemp "$STATE/.cs-plan-progress.XXXXXX" 2>/dev/null) || exit 0
if ! {
  printf '%s\n' "$PROGRESS" > "$TMP" \
    && chmod 0600 "$TMP" \
    && mv -f -- "$TMP" "$LAST"
}; then
  rm -f -- "$TMP" 2>/dev/null || true
  exit 0
fi

printf 'plan progress: remaining=%s total=%s\n' "$REMAINING" "$TOTAL"
