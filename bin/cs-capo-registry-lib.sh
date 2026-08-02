# shellcheck shell=bash
# shellcheck disable=SC2034 # the parsed fields are output globals for sourcing callers.
# cs-capo-registry-lib.sh - the single owner of data/capos.md parsing.
#
# Every reader of the capo routing table goes through this library:
# cs-home-seed.sh (seed validation and the bootstrap sweep), cs-fleet-view.sh
# (the fleet review), cs-backlog-handoff.sh (home resolution), and
# cs-teardown.sh (capo retirement). Nothing else may re-spell the format.
#
# RECORD SHAPE
#   - <id> - <summary> (home: <path>; scope: <text>; projects: <csv>; added YYYY-MM-DD)
# cs-home-seed.sh writes exactly that. The read path additionally accepts the
# degraded shape a hand edit or an older seed can leave behind:
#   - <id>[ - <summary>] (home: <path>; scope: <text>)
# `home:` and `scope:` are the only required fields, because they are the only
# ones any consumer routes or acts on. Anything else that begins "- " is
# MALFORMED and is surfaced to the caller, never silently skipped: a dropped row
# is how a second capo bound to an already-registered home slipped past
# validation.
#
# WHY THE PARSE IS ANCHORED
# Summary and scope are natural language and may contain both `;` and `()`, so
# field boundaries are anchored to the structured suffix markers and to end of
# line, never to the first incidental punctuation. `home:` and `projects:` stay
# `[^;)]*` because they are machine-written and delimiter-free; `scope:` runs to
# the anchored suffix so a semicolon or a parenthesis inside it cannot truncate
# it.
#
# WHY LOOKUP IS LITERAL
# A capo id may legally contain `.` (cs-home-seed.sh accepts [A-Za-z0-9._-]+),
# so interpolating an id into a regular expression makes `a.b` match a row for
# `axb`. Every lookup here validates the id charset and then matches the row
# LITERALLY. A caller that filters rows by id must use
# cs_capo_registry_line_is_id rather than building a pattern of its own.
#
# READS ARE EOF-SAFE AND FAIL CLOSED
# The read loop uses `|| [ -n "$line" ]` so a registry whose final line has no
# trailing newline still yields its last record. A missing, unreadable, or
# symlinked registry is refused with a reason in CS_CAPO_REGISTRY_ERROR rather
# than reported as an empty registry.
#
# Usage:
#   # shellcheck source=bin/cs-capo-registry-lib.sh
#   . "$SCRIPT_DIR/cs-capo-registry-lib.sh"

# Idempotent guard: sourcing twice must not reset a caller's parsed fields.
if [ -n "${CS_CAPO_REGISTRY_LIB_SOURCED:-}" ]; then
  return 0
fi
CS_CAPO_REGISTRY_LIB_SOURCED=1

# Fields set by cs_capo_registry_parse_line and every function built on it.
CS_CAPO_REGISTRY_ID=
CS_CAPO_REGISTRY_SUMMARY=
CS_CAPO_REGISTRY_HOME=
CS_CAPO_REGISTRY_SCOPE=
CS_CAPO_REGISTRY_PROJECTS=
CS_CAPO_REGISTRY_ADDED=
CS_CAPO_REGISTRY_LINE=
# The reason the last refusal refused. Callers print this; they never guess.
CS_CAPO_REGISTRY_ERROR=

_CS_CAPO_REGISTRY_TAB=$'\t'

# The canonical generated record, and the degraded home+scope-only record. They
# are tried in that order: the canonical pattern is strictly more specific, so a
# canonical line can never fall through and have its structured suffix swallowed
# into the scope text.
_CS_CAPO_REGISTRY_RE_FULL='^- ([A-Za-z0-9._-]+)( - (.+))? \(home:[[:space:]]*([^;)]*);[[:space:]]*scope:[[:space:]]*(.*);[[:space:]]*projects:[[:space:]]*([^;)]*);[[:space:]]*added[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})\)[[:space:]]*$'
_CS_CAPO_REGISTRY_RE_SHORT='^- ([A-Za-z0-9._-]+)( - (.+))? \(home:[[:space:]]*([^;)]*);[[:space:]]*scope:[[:space:]]*(.*)\)[[:space:]]*$'

# cs_capo_registry_valid_id <id> - the id charset cs-home-seed.sh enforces at
# seed time. Every lookup validates before matching, so a caller can never reach
# the literal matcher with a crafted id.
cs_capo_registry_valid_id() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# cs_capo_registry_line_is_id <line> <id> - does this registry line belong to
# this capo? Literal, never a pattern: the id is compared as text.
cs_capo_registry_line_is_id() {
  local line=$1 id=$2
  cs_capo_registry_valid_id "$id" || return 1
  [ "$line" = "- $id" ] && return 0
  case "$line" in
    "- $id "*) return 0 ;;
  esac
  return 1
}

_cs_capo_registry_clear_fields() {
  CS_CAPO_REGISTRY_ID=
  CS_CAPO_REGISTRY_SUMMARY=
  CS_CAPO_REGISTRY_HOME=
  CS_CAPO_REGISTRY_SCOPE=
  CS_CAPO_REGISTRY_PROJECTS=
  CS_CAPO_REGISTRY_ADDED=
  CS_CAPO_REGISTRY_LINE=
}

_cs_capo_registry_rtrim() {  # <varname> - strip trailing whitespace in place
  local name=$1
  local value=${!name}
  while :; do
    case "$value" in
      *[[:space:]]) value=${value%?} ;;
      *) break ;;
    esac
  done
  printf -v "$name" '%s' "$value"
}

# cs_capo_registry_parse_line <line> - parse one "- ..." row into the field
# globals. rc=1 (with the globals cleared) means MALFORMED; the caller decides
# whether that refuses, warns, or renders a reason, but it never ignores it.
cs_capo_registry_parse_line() {
  local line=$1
  _cs_capo_registry_clear_fields
  CS_CAPO_REGISTRY_LINE=$line
  # A tab would collide with the tab-delimited record stream below, and no
  # generated line can contain one (the writer collapses whitespace to spaces).
  case "$line" in
    *"$_CS_CAPO_REGISTRY_TAB"*) return 1 ;;
  esac
  if [[ $line =~ $_CS_CAPO_REGISTRY_RE_FULL ]]; then
    CS_CAPO_REGISTRY_ID=${BASH_REMATCH[1]}
    CS_CAPO_REGISTRY_SUMMARY=${BASH_REMATCH[3]}
    CS_CAPO_REGISTRY_HOME=${BASH_REMATCH[4]}
    CS_CAPO_REGISTRY_SCOPE=${BASH_REMATCH[5]}
    CS_CAPO_REGISTRY_PROJECTS=${BASH_REMATCH[6]}
    CS_CAPO_REGISTRY_ADDED=${BASH_REMATCH[7]}
  elif [[ $line =~ $_CS_CAPO_REGISTRY_RE_SHORT ]]; then
    CS_CAPO_REGISTRY_ID=${BASH_REMATCH[1]}
    CS_CAPO_REGISTRY_SUMMARY=${BASH_REMATCH[3]}
    CS_CAPO_REGISTRY_HOME=${BASH_REMATCH[4]}
    CS_CAPO_REGISTRY_SCOPE=${BASH_REMATCH[5]}
  else
    return 1
  fi
  _cs_capo_registry_rtrim CS_CAPO_REGISTRY_HOME
  _cs_capo_registry_rtrim CS_CAPO_REGISTRY_SCOPE
  _cs_capo_registry_rtrim CS_CAPO_REGISTRY_PROJECTS
  # home and scope are what consumers route and act on; a row without both is
  # malformed, and must leave nothing half-parsed behind for the caller to read.
  if [ -z "$CS_CAPO_REGISTRY_HOME" ] || [ -z "$CS_CAPO_REGISTRY_SCOPE" ]; then
    _cs_capo_registry_clear_fields
    CS_CAPO_REGISTRY_LINE=$line
    return 1
  fi
  return 0
}

# cs_capo_registry_exists <reg> - is there anything at this path at all?
# A dangling symlink counts: it exists as a thing the caller must not silently
# read as "no registry".
cs_capo_registry_exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

# cs_capo_registry_available <reg> - refuse anything that is not the ordinary
# readable file the fleet writes. Sets CS_CAPO_REGISTRY_ERROR on refusal.
cs_capo_registry_available() {
  local reg=$1
  CS_CAPO_REGISTRY_ERROR=
  if [ -L "$reg" ]; then
    CS_CAPO_REGISTRY_ERROR="capo registry is a symlink, not the ordinary file the fleet writes: $reg"
    return 1
  fi
  if [ ! -e "$reg" ]; then
    CS_CAPO_REGISTRY_ERROR="no capo registry at $reg"
    return 1
  fi
  if [ ! -f "$reg" ]; then
    CS_CAPO_REGISTRY_ERROR="capo registry is not an ordinary file: $reg"
    return 1
  fi
  if [ ! -r "$reg" ]; then
    CS_CAPO_REGISTRY_ERROR="capo registry is unreadable: $reg"
    return 1
  fi
  return 0
}

_cs_capo_registry_text() {  # <reg> [max_bytes] -> registry text on stdout
  local reg=$1 max_bytes=${2:-} text bytes
  if [ -z "$max_bytes" ]; then
    cat "$reg"
    return 0
  fi
  text=$(head -c "$max_bytes" "$reg"; printf X)
  text=${text%X}
  bytes=$(printf '%s' "$text" | wc -c | tr -d ' ')
  if [ "$bytes" -lt "$max_bytes" ]; then
    printf '%s' "$text"
    return 0
  fi
  # The bound stopped the read mid-file, so a final line with no newline is a
  # CUT TAIL, not a genuine EOF-truncated record. Drop it rather than report a
  # half-read row as malformed. A file that ends short of the bound keeps its
  # unterminated last line, which is the EOF-safety contract above.
  case "$text" in
    '') ;;
    *$'\n') printf '%s' "$text" ;;
    *$'\n'*) printf '%s\n' "${text%$'\n'*}" ;;
  esac
  return 0
}

# cs_capo_registry_records <reg> [max_bytes] - the whole registry as one
# tab-delimited record per "- " row, for the callers that need to walk it:
#
#   <status>\t<id>\t<home>\t<scope>\t<raw line>
#
# status is `ok` or `malformed`. NO FIELD IS EVER EMPTY (a malformed record
# carries "-" placeholders and an ok record's id, home, and scope are all
# required), because tab is IFS whitespace and adjacent empty fields would
# collapse on read. The raw line is last so it may contain anything.
# Read them with:  while IFS=$'\t' read -r status id home scope raw; do
#
# rc=1 means the registry itself is missing, unreadable, or unsafe. An existing
# but empty registry succeeds with no output.
#
# CALLERS THAT CAPTURE THIS WITH $(...) MUST CALL cs_capo_registry_available
# FIRST: a command substitution runs in a subshell, so the reason this function
# writes to CS_CAPO_REGISTRY_ERROR never reaches the caller's shell. Checking
# availability in the caller's own shell is what makes the reason printable.
cs_capo_registry_records() {
  local reg=$1 max_bytes=${2:-} line
  cs_capo_registry_available "$reg" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    if cs_capo_registry_parse_line "$line"; then
      printf 'ok\t%s\t%s\t%s\t%s\n' \
        "$CS_CAPO_REGISTRY_ID" "$CS_CAPO_REGISTRY_HOME" "$CS_CAPO_REGISTRY_SCOPE" "$line"
    else
      printf 'malformed\t-\t-\t-\t%s\n' "$line"
    fi
  done < <(_cs_capo_registry_text "$reg" "$max_bytes")
}

# cs_capo_registry_line_for_id <reg> <id> - find the ONE row for this capo and
# leave it parsed in the field globals. Refuses an invalid id, an unavailable
# registry, a missing entry, a malformed entry, and - deliberately - DUPLICATE
# entries: silently taking the last of two rows is how a stale home survives a
# rebind. Sets CS_CAPO_REGISTRY_ERROR on every refusal.
cs_capo_registry_line_for_id() {
  local reg=$1 id=$2 line count=0 found=
  CS_CAPO_REGISTRY_ERROR=
  if ! cs_capo_registry_valid_id "$id"; then
    CS_CAPO_REGISTRY_ERROR="capo id must be [A-Za-z0-9._-]+: '$id'"
    return 1
  fi
  cs_capo_registry_available "$reg" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    cs_capo_registry_line_is_id "$line" "$id" || continue
    count=$((count + 1))
    found=$line
  done < "$reg"
  if [ "$count" -eq 0 ]; then
    CS_CAPO_REGISTRY_ERROR="capo $id is not registered in $reg"
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    CS_CAPO_REGISTRY_ERROR="capo $id has $count entries in $reg; resolve the duplicate before routing to it"
    return 1
  fi
  if ! cs_capo_registry_parse_line "$found"; then
    CS_CAPO_REGISTRY_ERROR="malformed capo registry entry: $found"
    return 1
  fi
  return 0
}

# cs_capo_registry_field <reg> <id> <home|scope|projects|summary|added> - print
# one field of the single matching row, or rc=1 with CS_CAPO_REGISTRY_ERROR.
cs_capo_registry_field() {
  local reg=$1 id=$2 key=$3
  cs_capo_registry_line_for_id "$reg" "$id" || return 1
  case "$key" in
    home) printf '%s\n' "$CS_CAPO_REGISTRY_HOME" ;;
    scope) printf '%s\n' "$CS_CAPO_REGISTRY_SCOPE" ;;
    projects) printf '%s\n' "$CS_CAPO_REGISTRY_PROJECTS" ;;
    summary) printf '%s\n' "$CS_CAPO_REGISTRY_SUMMARY" ;;
    added) printf '%s\n' "$CS_CAPO_REGISTRY_ADDED" ;;
    *)
      CS_CAPO_REGISTRY_ERROR="unknown capo registry field: $key"
      return 1
      ;;
  esac
}
