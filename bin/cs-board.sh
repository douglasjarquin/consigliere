#!/usr/bin/env bash
# GitHub Projects (v2) board access for consigliere's board-driven work.
# The mechanical half of the `contracts` and `casino` skills: list Inbox and
# Ready issues, move a card to Backlog after its spec lands or to In Progress
# at dispatch, and read a card's current status. It deliberately
# NEVER moves a card to Done - that is owned by the board's built-in
# "when issue closed -> Done" workflow, triggered by a merged PR whose body
# carries `Closes #<n>` (see the contracts skill and cs-brief.sh --issue).
# It also NEVER moves a card to Ready - Backlog -> Ready is the boss's human
# approval gate (see the casino skill) and has no command here on purpose.
#
# Board identity comes from config/boards.md (LOCAL, gitignored), a durable
# per-project record kept beside config/projects.md and keyed by the same project
# name. Blank lines and lines beginning with '#' are ignored; every other line
# is one mapping:
#   <project-name> <owner> <project-number> [ready-label] [inprogress-label] [status-field] [inbox-label] [backlog-label]
# Defaults: ready-label="Ready", inprogress-label="In Progress",
# status-field="Status", inbox-label="Inbox", backlog-label="Backlog".
# <owner> is a user or org login, or "@me" for the authenticated user.
#
# Commands:
#   cs-board.sh ready <project>            TSV of open Ready issues:
#                                          <item-id>\t<number>\t<url>\t<title>
#   cs-board.sh inbox <project>            same TSV for open Inbox issues
#                                          (draft cards are never listed; convert
#                                          a draft to an issue to make it workable)
#   cs-board.sh counts <project>           "ready=<n>" and "inbox=<n>" from ONE
#                                          item-list call, for the cheap sweep
#                                          poll armed by cs-board-watch.sh
#   cs-board.sh start <project> <item-id>  set the card's Status -> In Progress
#   cs-board.sh specced <project> <item-id> set the card's Status -> Backlog
#                                          (after a verified spec; casino skill)
#   cs-board.sh status <project> <item-id> print the card's current Status name
#   cs-board.sh mapped <project>           exit 0 if the project has a mapping
#                                          line; no network, no output. Callers
#                                          ask here instead of re-parsing
#                                          boards.md themselves.
#   cs-board.sh check <project>            read-only board sanity + a reminder
#                                          that the closed->Done workflow must
#                                          be enabled (built-in-only Done move)
#   cs-board.sh ids <project>              debug: resolved project/field/option ids
#
# Requires gh (with the `project` token scope) and jq. gh project is not wrapped
# by gh-axi, so this script calls gh directly; issue/PR work still goes through
# gh-axi elsewhere.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
BOARDS="$CONFIG/boards.md"

# Test seam: point CS_BOARD_GH at a fake gh for offline tests.
GH=${CS_BOARD_GH:-gh}

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"
}

die() { echo "cs-board: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required"

# resolve <project> -> sets OWNER NUMBER READY_LABEL INPROGRESS_LABEL
# STATUS_FIELD INBOX_LABEL BACKLOG_LABEL
resolve_board() {
  local project=$1 line
  [ -f "$BOARDS" ] || die "no board mapping at $BOARDS; add a line: <project> <owner> <number> [ready] [in-progress] [status-field] [inbox] [backlog]"
  # Skip blank lines and '#' comments so the file reads as ordinary markdown.
  line=$(awk -v p="$project" '/^[[:space:]]*#/ {next} $1==p {print; exit}' "$BOARDS")
  [ -n "$line" ] || die "project '$project' not in $BOARDS"
  # shellcheck disable=SC2086 # deliberate word split of the config line
  set -- $line
  OWNER=$2
  NUMBER=$3
  READY_LABEL=${4:-Ready}
  INPROGRESS_LABEL=${5:-In Progress}
  STATUS_FIELD=${6:-Status}
  INBOX_LABEL=${7:-Inbox}
  BACKLOG_LABEL=${8:-Backlog}
  # Underscores in config stand in for spaces so labels stay single tokens.
  READY_LABEL=${READY_LABEL//_/ }
  INPROGRESS_LABEL=${INPROGRESS_LABEL//_/ }
  STATUS_FIELD=${STATUS_FIELD//_/ }
  INBOX_LABEL=${INBOX_LABEL//_/ }
  BACKLOG_LABEL=${BACKLOG_LABEL//_/ }
  case "$NUMBER" in ''|*[!0-9]*) die "board number for '$project' must be numeric, got '$NUMBER'" ;; esac
}

project_json() {
  $GH project view "$NUMBER" --owner "$OWNER" --format json 2>/dev/null \
    || die "cannot read project $NUMBER for owner $OWNER (is gh authed with the 'project' scope?)"
}

field_json() {
  $GH project field-list "$NUMBER" --owner "$OWNER" --format json 2>/dev/null \
    || die "cannot list fields for project $NUMBER (owner $OWNER)"
}

items_json() {
  # -L caps the page; boards with more matching items than this need --limit tuning.
  $GH project item-list "$NUMBER" --owner "$OWNER" --format json --limit "${CS_BOARD_ITEM_LIMIT:-200}" 2>/dev/null \
    || die "cannot list items for project $NUMBER (owner $OWNER)"
}

# resolve_ids: sets PROJECT_ID FIELD_ID READY_OPT INPROGRESS_OPT DONE_OPT
# INBOX_OPT BACKLOG_OPT
resolve_ids() {
  local pj fj
  pj=$(project_json)
  PROJECT_ID=$(printf '%s' "$pj" | jq -r '.id // empty')
  [ -n "$PROJECT_ID" ] || die "could not resolve the project node id"
  fj=$(field_json)
  FIELD_ID=$(printf '%s' "$fj" | jq -r --arg n "$STATUS_FIELD" '.fields[] | select(.name==$n) | .id' | head -1)
  [ -n "$FIELD_ID" ] || die "no '$STATUS_FIELD' single-select field on this board"
  READY_OPT=$(printf '%s' "$fj" | jq -r --arg n "$STATUS_FIELD" --arg o "$READY_LABEL" '.fields[] | select(.name==$n) | .options[]? | select(.name==$o) | .id' | head -1)
  INPROGRESS_OPT=$(printf '%s' "$fj" | jq -r --arg n "$STATUS_FIELD" --arg o "$INPROGRESS_LABEL" '.fields[] | select(.name==$n) | .options[]? | select(.name==$o) | .id' | head -1)
  DONE_OPT=$(printf '%s' "$fj" | jq -r --arg n "$STATUS_FIELD" '.fields[] | select(.name==$n) | .options[]? | select(.name=="Done") | .id' | head -1)
  INBOX_OPT=$(printf '%s' "$fj" | jq -r --arg n "$STATUS_FIELD" --arg o "$INBOX_LABEL" '.fields[] | select(.name==$n) | .options[]? | select(.name==$o) | .id' | head -1)
  BACKLOG_OPT=$(printf '%s' "$fj" | jq -r --arg n "$STATUS_FIELD" --arg o "$BACKLOG_LABEL" '.fields[] | select(.name==$n) | .options[]? | select(.name==$o) | .id' | head -1)
}

# open_issues_of <items-json> <column-label>: TSV of open Issues whose Status
# matches. The single-select field value renders under the lowercased field name
# key in gh's item JSON (e.g. "status"); filter client-side so the command works
# regardless of whether the API host supports server-side --query.
# Taking the JSON as an argument lets a caller that needs two columns pay for
# one item-list call instead of two (see cmd_counts).
open_issues_of() {
  local json=$1 col=$2 key
  key=$(printf '%s' "$STATUS_FIELD" | tr '[:upper:] ' '[:lower:]_')
  printf '%s' "$json" | jq -r --arg col "$col" --arg key "$key" '
    .items[]
    | select((.[$key] // .status) == $col)
    | select(.content.type == "Issue")
    | select((.content.state // "OPEN") | ascii_upcase == "OPEN")
    | [.id, (.content.number|tostring), .content.url, .content.title]
    | @tsv
  '
}

list_open_issues() {
  open_issues_of "$(items_json)" "$1"
}

item_status() {
  local item=$1 key
  key=$(printf '%s' "$STATUS_FIELD" | tr '[:upper:] ' '[:lower:]_')
  items_json | jq -r --arg id "$item" --arg key "$key" '
    .items[] | select(.id==$id) | (.[$key] // .status // "(unset)")
  '
}

cmd_ready() {
  local project=$1
  resolve_board "$project"
  list_open_issues "$READY_LABEL"
}

cmd_inbox() {
  local project=$1
  resolve_board "$project"
  list_open_issues "$INBOX_LABEL"
}

# Depth of the two columns a sweep pulls from, in one item-list call, as
# "ready=<n>" and "inbox=<n>". This is what the armed sweep poll runs every
# watcher check interval, so it must stay to a single API round trip and must
# never move a card. A board with no Inbox column simply reports inbox=0.
cmd_counts() {
  local project=$1 json ready inbox
  resolve_board "$project"
  json=$(items_json)
  ready=$(open_issues_of "$json" "$READY_LABEL" | grep -c . || true)
  inbox=$(open_issues_of "$json" "$INBOX_LABEL" | grep -c . || true)
  printf 'ready=%s\ninbox=%s\n' "$ready" "$inbox"
}

validate_board_options() {
  local -a role_names=("Ready" "In Progress" "Done" "Inbox" "Backlog")
  local -a role_labels=("$READY_LABEL" "$INPROGRESS_LABEL" "Done" "$INBOX_LABEL" "$BACKLOG_LABEL")
  local -a role_options=("$READY_OPT" "$INPROGRESS_OPT" "$DONE_OPT" "$INBOX_OPT" "$BACKLOG_OPT")
  local i j
  for ((i = 0; i < ${#role_options[@]}; i += 1)); do
    [ -n "${role_options[i]}" ] || continue
    for ((j = i + 1; j < ${#role_options[@]}; j += 1)); do
      [ -n "${role_options[j]}" ] || continue
      [ "${role_options[i]}" != "${role_options[j]}" ] || die "${role_names[i]} option '${role_labels[i]}' aliases ${role_names[j]} option '${role_labels[j]}'"
    done
  done
}

cmd_start() {
  local project=$1 item=$2 current
  [ -n "$item" ] || die "usage: cs-board.sh start <project> <item-id>"
  resolve_board "$project"
  resolve_ids
  validate_board_options
  [ -n "$INPROGRESS_OPT" ] || die "no '$INPROGRESS_LABEL' option on the '$STATUS_FIELD' field"
  current=$(item_status "$item")
  [ "$current" = "$READY_LABEL" ] || die "item $item must be in '$READY_LABEL' before moving to '$INPROGRESS_LABEL' (current: ${current:-unset})"
  $GH project item-edit --id "$item" --field-id "$FIELD_ID" --project-id "$PROJECT_ID" --single-select-option-id "$INPROGRESS_OPT" >/dev/null \
    || die "failed to move item $item to '$INPROGRESS_LABEL'"
  echo "moved $item -> $INPROGRESS_LABEL"
}

cmd_specced() {
  local project=$1 item=$2 current
  [ -n "$item" ] || die "usage: cs-board.sh specced <project> <item-id>"
  resolve_board "$project"
  resolve_ids
  validate_board_options
  [ -n "$INBOX_OPT" ] || die "no '$INBOX_LABEL' option on the '$STATUS_FIELD' field"
  [ -n "$BACKLOG_OPT" ] || die "no '$BACKLOG_LABEL' option on the '$STATUS_FIELD' field"
  current=$(item_status "$item")
  [ "$current" = "$INBOX_LABEL" ] || die "item $item must be in '$INBOX_LABEL' before moving to '$BACKLOG_LABEL' (current: ${current:-unset})"
  $GH project item-edit --id "$item" --field-id "$FIELD_ID" --project-id "$PROJECT_ID" --single-select-option-id "$BACKLOG_OPT" >/dev/null \
    || die "failed to move item $item to '$BACKLOG_LABEL'"
  echo "moved $item -> $BACKLOG_LABEL"
}

cmd_status() {
  local project=$1 item=$2
  [ -n "$item" ] || die "usage: cs-board.sh status <project> <item-id>"
  resolve_board "$project"
  item_status "$item"
}

cmd_check() {
  local project=$1
  resolve_board "$project"
  resolve_ids
  echo "board: $OWNER/#$NUMBER  status-field='$STATUS_FIELD'"
  printf 'options: Ready=%s  In-Progress=%s  Done=%s  Inbox=%s  Backlog=%s\n' \
    "${READY_OPT:+ok}" "${INPROGRESS_OPT:+ok}" "${DONE_OPT:+ok}" \
    "${INBOX_OPT:+ok}" "${BACKLOG_OPT:+ok}"
  [ -n "$READY_OPT" ] || echo "WARN: no '$READY_LABEL' option - the sweep will find nothing to dispatch"
  [ -n "$INPROGRESS_OPT" ] || echo "WARN: no '$INPROGRESS_LABEL' option - cards cannot be moved at dispatch"
  [ -n "$DONE_OPT" ] || echo "WARN: no 'Done' option - the closed->Done workflow has nowhere to move cards"
  [ -n "$INBOX_OPT" ] || echo "WARN: no '$INBOX_LABEL' option - the casino spec sweep will find nothing (contracts alone does not need it)"
  [ -n "$BACKLOG_OPT" ] || echo "WARN: no '$BACKLOG_LABEL' option - specced cards cannot be parked for the boss's gate (contracts alone does not need it)"
  cat <<'EOF'
NOTE: consigliere moves a card only to Backlog (after a verified spec) or to
In Progress (at dispatch). Backlog -> Ready is the boss's human approval gate
and this script has no command for it. The card reaches Done ONLY
through the board's built-in workflow "when an issue is closed -> set Status
Done", fired by a merged PR carrying `Closes #<n>`. Enable that workflow once in
the project's Workflows settings; consigliere will read-only-verify cards left
In Progress after merge and warn if any are stuck, but it never sets Done itself.
EOF
}

# Mapping existence only, so a caller can fail closed on an unmapped project
# without duplicating the boards.md format. resolve_board already dies with the
# actionable message, so this only has to silence its success path.
cmd_mapped() {
  local project=$1
  resolve_board "$project" >/dev/null
}

cmd_ids() {
  local project=$1
  resolve_board "$project"
  resolve_ids
  printf 'project_id=%s\nfield_id=%s\nready_opt=%s\ninprogress_opt=%s\ndone_opt=%s\ninbox_opt=%s\nbacklog_opt=%s\n' \
    "$PROJECT_ID" "$FIELD_ID" "$READY_OPT" "$INPROGRESS_OPT" "$DONE_OPT" "$INBOX_OPT" "$BACKLOG_OPT"
}

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
  ready)   [ $# -ge 2 ] || die "usage: cs-board.sh ready <project>"; cmd_ready "$2" ;;
  inbox)   [ $# -ge 2 ] || die "usage: cs-board.sh inbox <project>"; cmd_inbox "$2" ;;
  counts)  [ $# -ge 2 ] || die "usage: cs-board.sh counts <project>"; cmd_counts "$2" ;;
  start)   [ $# -ge 3 ] || die "usage: cs-board.sh start <project> <item-id>"; cmd_start "$2" "$3" ;;
  specced) [ $# -ge 3 ] || die "usage: cs-board.sh specced <project> <item-id>"; cmd_specced "$2" "$3" ;;
  status)  [ $# -ge 3 ] || die "usage: cs-board.sh status <project> <item-id>"; cmd_status "$2" "$3" ;;
  mapped)  [ $# -ge 2 ] || die "usage: cs-board.sh mapped <project>"; cmd_mapped "$2" ;;
  check)   [ $# -ge 2 ] || die "usage: cs-board.sh check <project>"; cmd_check "$2" ;;
  ids)     [ $# -ge 2 ] || die "usage: cs-board.sh ids <project>"; cmd_ids "$2" ;;
  *) die "unknown command '$1' (ready|inbox|counts|start|specced|status|mapped|check|ids)" ;;
esac
