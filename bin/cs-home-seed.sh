#!/usr/bin/env bash
# Provision, validate, and sweep persistent capo homes.
#
# Usage:
#   cs-home-seed.sh <id> {<project>...|--no-projects}
#       Provision ${CS_CAPOS_ROOT:-~/.consigliere/capos}/<id> as an isolated
#       capo home: a PLAIN DETACHED git worktree of this consigliere repo
#       (never a herdr-managed worktree - a capo home must survive server
#       restarts and empty workspaces), marked with a .cs-capo-home file
#       containing the capo id. The home's private data/, state/, config/, and
#       projects/ dirs are created; each named project is cloned from its
#       origin into <home>/projects/ (the list is non-exclusive provisioning
#       data, and local-only projects are refused); the filled charter brief at
#       data/<id>/brief.md is copied to <home>/config/charter.md; the tiny
#       inheritance surface (bin/cs-inherit-lib.sh: config/boss-shared.md
#       read-only plus config/backlog-backend.conf) is seeded; and the routing
#       entry is written to host/capos.md as
#         - <id> - <summary> (home: <path>; scope: <scope>; projects: <csv>; added <date>)
#       This script writes that line; bin/cs-capo-registry-lib.sh is the single
#       owner of reading it back, here and in every other consumer.
#       Pass --no-projects for a project-less domain whose subject is the
#       consigliere repo itself; it is mutually exclusive with a project list,
#       and omitting both fails loudly. A project-less seed refuses a home
#       with project clones or project-registry entries.
#       Set CS_CAPO_CHARTER='<charter>' to scaffold and fill the charter when
#       no filled brief exists, and CS_CAPO_SCOPE='<scope>' for a routing
#       scope distinct from the charter text.
#       Seeding is TRANSACTIONAL: on any validation, worktree, clone, init,
#       inheritance, or registry failure, generated briefs, the new home
#       worktree, new project clones, and registry edits are all rolled back.
#   cs-home-seed.sh validate
#       Refuse duplicate ids, duplicate homes, nested or overlapping homes, and
#       any malformed entry in host/capos.md. A row that does not parse is
#       refused rather than skipped: a silently dropped row is a binding the
#       duplicate-home and rebind checks never see.
#   cs-home-seed.sh --sweep
#       The locked bootstrap sweep (bin/cs-bootstrap.sh):
#       1. Fast-forward every registered capo home to this repo's current
#          default-branch tip - a purely local detached-HEAD advance, FF-only,
#          never forcing, merging, or stashing; dirty or diverged homes are
#          skipped with a CAPO_SYNC: line and their work left untouched.
#          The same pass converges the inherited config/boss-shared.md copy, and
#          fills an ABSENT host/activation.conf with "always" so a home seeded
#          before per-home activation existed stops resolving to afk-only and
#          can start its own turns. A present value is never overwritten.
#       2. Liveness-guarantee every live capo meta (state/<id>.meta with
#          kind=capo): probe the recorded pane for a real agent through
#          bin/cs-herdr-lib.sh, respawn via cs-spawn.sh <id> <home> --capo
#          ONLY on a confident dead reading, and report skipped or failed
#          guarantees as CAPO_LIVENESS: lines. An inconclusive probe is never
#          acted on: a false-dead reading would spawn a duplicate supervisor,
#          while a false-alive reading merely waits one more sweep.
#          A kind=capo meta with no recorded endpoint is a broken record: it is
#          reported as a CAPO_LIVENESS: line for the recovery path rather than
#          skipped invisibly, and never respawned, because there is no endpoint
#          to probe and AGENTS.md section 5 forbids sweeping herdr by name to
#          find one. A registered capo with no meta at all is NOT reported here:
#          that is the ordinary seeded-but-not-yet-launched state, and this
#          sweep cannot distinguish it from a lost record without inventing a
#          launch marker for a case that has never occurred.
#       Silent output means every registered capo is current and running.
#
# CS_CAPOS_ROOT overrides the capo home pool root (default
# ~/.consigliere/capos). CS_HOME_SEED_SPAWN_BIN overrides the respawn helper
# (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
esac

# shellcheck source=bin/cs-capo-registry-lib.sh
. "$SCRIPT_DIR/cs-capo-registry-lib.sh"
# shellcheck source=bin/cs-inherit-lib.sh
. "$SCRIPT_DIR/cs-inherit-lib.sh"
# shellcheck source=bin/cs-herdr-lib.sh
. "$SCRIPT_DIR/cs-herdr-lib.sh"
# shellcheck source=bin/cs-made-lib.sh
. "$SCRIPT_DIR/cs-made-lib.sh"
# The two sweep halves below, and each capo inside them, carry one elapsed-time
# record. Inert unless the run that launched this one asked for recording
# (bin/cs-timing-lib.sh).
# shellcheck source=bin/cs-timing-lib.sh
. "$SCRIPT_DIR/cs-timing-lib.sh"

# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
PROJECTS="${CS_PROJECTS_OVERRIDE:-$CS_HOME/projects}"
CAPOS_ROOT="${CS_CAPOS_ROOT:-$HOME/.consigliere/capos}"
REG="$HOST_DIR/capos.md"
MARKER=".cs-capo-home"
SPAWN_BIN="${CS_HOME_SEED_SPAWN_BIN:-$SCRIPT_DIR/cs-spawn.sh}"

# --- shared helpers ----------------------------------------------------------

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

resolved_path() {  # best-effort canonical absolute path (existing or not)
  local p=$1 parent
  case "$p" in
    /*) ;;
    *) p="$(pwd -P)/$p" ;;
  esac
  if [ -d "$p" ]; then
    (cd "$p" && pwd -P)
    return 0
  fi
  parent=$(dirname "$p")
  if [ -d "$parent" ]; then
    (cd "$parent" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$p")")
    return 0
  fi
  printf '%s\n' "$p"
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] && [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

# Refuse any capo-home path that is (or contains, or lives inside) the active
# home or the consigliere repo checkout.
refuse_unsafe_home_path() {
  local home=$1 abs_home abs_active abs_root
  abs_home=$(resolved_path "$home")
  abs_active=$(resolved_path "$CS_HOME")
  abs_root=$(resolved_path "$CS_ROOT")
  [ "$abs_home" != "/" ] || { echo "error: capo home cannot be the filesystem root: $home" >&2; return 1; }
  if [ "$abs_home" = "$abs_active" ] || [ "$abs_home" = "$abs_root" ]; then
    echo "error: capo home cannot be the active consigliere home or repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active" "$abs_home" || path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: capo home cannot be inside the active consigliere home or repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active" || path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: capo home cannot be an ancestor of the active consigliere home or repo: $home" >&2
    return 1
  fi
}

# The commit every capo home follows: this repo's default-branch tip (never a
# stray feature branch the primary checkout might be stranded on), falling
# back to HEAD for a repo with no named default branch.
seed_commit() {
  local ref branch
  ref=$(git -C "$CS_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  ref=${ref#origin/}
  if [ -z "$ref" ]; then
    for branch in main master; do
      if git -C "$CS_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
        ref=$branch
        break
      fi
    done
  fi
  if [ -n "$ref" ]; then
    git -C "$CS_ROOT" rev-parse --verify --quiet "refs/heads/$ref^{commit}" && return 0
  fi
  git -C "$CS_ROOT" rev-parse --verify --quiet 'HEAD^{commit}'
}

home_is_worktree_of_root() {  # <home>
  local home=$1 common root_common
  common=$(git -C "$home" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  root_common=$(git -C "$CS_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] && [ "$common" = "$root_common" ]
}

# --- registry helpers ---------------------------------------------------------

# Every registry read goes through bin/cs-capo-registry-lib.sh; this is the one
# place that turns "no registry yet" (a normal pre-first-seed state) into an
# empty record set and anything else unreadable into a refusal.
#
# The records land in a GLOBAL rather than on stdout because the availability
# reason must be readable by the caller: a $(...) capture would run the check in
# a subshell and lose it.
REGISTRY_RECORDS=
REGISTRY_RECORDS_ERROR=
load_registry_records() {  # sets REGISTRY_RECORDS; rc=1 sets REGISTRY_RECORDS_ERROR
  REGISTRY_RECORDS=
  REGISTRY_RECORDS_ERROR=
  cs_capo_registry_exists "$REG" || return 0
  if ! cs_capo_registry_available "$REG"; then
    REGISTRY_RECORDS_ERROR=$CS_CAPO_REGISTRY_ERROR
    return 1
  fi
  if ! REGISTRY_RECORDS=$(cs_capo_registry_records "$REG"); then
    REGISTRY_RECORDS_ERROR="capo registry could not be read: $REG"
    return 1
  fi
  return 0
}

normalize_registry_text() {
  awk '
    {
      gsub(/[;()]/, " ")
      gsub(/[[:space:]]+/, " ")
      sub(/^ /, "")
      sub(/ $/, "")
      if ($0 != "") {
        out = out (out == "" ? "" : " ") $0
      }
    }
    END { print out }
  '
}

brief_section_text() {
  local brief=$1 heading=$2
  awk -v heading="# $heading" '
    $0 == heading { in_section=1; next }
    in_section && /^# / { exit }
    in_section { print }
  ' "$brief"
}

registry_summary_for_brief() {
  local brief=$1
  if [ -n "${CS_CAPO_CHARTER:-}" ]; then
    printf '%s\n' "$CS_CAPO_CHARTER" | normalize_registry_text
  else
    brief_section_text "$brief" "Charter" | normalize_registry_text
  fi
}

registry_scope_for_brief() {
  local brief=$1
  if [ -n "${CS_CAPO_SCOPE:-}" ]; then
    printf '%s\n' "$CS_CAPO_SCOPE" | normalize_registry_text
  else
    brief_section_text "$brief" "Routing scope" | normalize_registry_text
  fi
}

validate_registry_home_text() {
  local home=$1
  case "$home" in
    *';'*|*')'*|*$'\n'*)
      echo "error: capo home path contains registry delimiters: $home" >&2
      return 1
      ;;
  esac
}

validate_registry() {
  local tmp status id registered_home scope raw home_key
  local duplicate_homes duplicate_ids overlaps
  load_registry_records || {
    echo "error: $REGISTRY_RECORDS_ERROR" >&2
    return 1
  }
  tmp=$(mktemp "${TMPDIR:-/tmp}/cs-capos.XXXXXX")
  if [ -n "$REGISTRY_RECORDS" ]; then
    while IFS=$'\t' read -r status id registered_home scope raw; do
      if [ "$status" != ok ]; then
        rm -f "$tmp"
        echo "error: malformed capo registry entry in $REG: $raw" >&2
        return 1
      fi
      home_key=$(resolved_path "$registered_home")
      printf '%s\t%s\n' "$home_key" "$id" >> "$tmp"
    done <<< "$REGISTRY_RECORDS"
  fi
  duplicate_homes=$(awk -F '\t' '
    {
      if (($1 in owner) && owner[$1] != $2) {
        print $1 ": " owner[$1] ", " $2
        bad=1
      } else {
        owner[$1]=$2
      }
    }
    END { exit bad ? 1 : 0 }
  ' "$tmp" 2>/dev/null) || {
    rm -f "$tmp"
    printf 'error: duplicate capo home assignment:\n%s\n' "$duplicate_homes" >&2
    return 1
  }
  duplicate_ids=$(awk -F '\t' '
    {
      if ($2 in home) {
        print $2 ": " home[$2] ", " $1
        bad=1
      } else {
        home[$2]=$1
      }
    }
    END { exit bad ? 1 : 0 }
  ' "$tmp" 2>/dev/null) || {
    rm -f "$tmp"
    printf 'error: duplicate capo id assignment:\n%s\n' "$duplicate_ids" >&2
    return 1
  }
  overlaps=$(awk -F '\t' '
    function ancestor(a, b) { return a != b && index(b, a "/") == 1 }
    {
      for (i = 1; i <= count; i++) {
        if (ancestor($1, path[i])) {
          print $1 " (" $2 ") contains " path[i] " (" id[i] ")"
          bad=1
        } else if (ancestor(path[i], $1)) {
          print path[i] " (" id[i] ") contains " $1 " (" $2 ")"
          bad=1
        }
      }
      count++
      path[count]=$1
      id[count]=$2
    }
    END { exit bad ? 1 : 0 }
  ' "$tmp" 2>/dev/null) || {
    rm -f "$tmp"
    printf 'error: overlapping capo home assignment:\n%s\n' "$overlaps" >&2
    return 1
  }
  rm -f "$tmp"
  return 0
}

validate_home_assignment() {  # <id> <home>
  local id=$1 home=$2 marker_id target
  local status registered_id registered_home scope raw registered_key
  if [ -f "$home/$MARKER" ]; then
    marker_id=$(cat "$home/$MARKER" 2>/dev/null || true)
    if [ "$marker_id" != "$id" ]; then
      echo "error: capo home $home is already marked for ${marker_id:-unknown}" >&2
      return 1
    fi
  fi
  load_registry_records || {
    echo "error: $REGISTRY_RECORDS_ERROR" >&2
    return 1
  }
  [ -n "$REGISTRY_RECORDS" ] || return 0
  target=$(resolved_path "$home")
  # The here-string keeps this loop in the current shell, so a refusal below
  # returns from the function instead of dying in a subshell.
  while IFS=$'\t' read -r status registered_id registered_home scope raw; do
    if [ "$status" != ok ]; then
      echo "error: malformed capo registry entry in $REG: $raw" >&2
      return 1
    fi
    registered_key=$(resolved_path "$registered_home")
    if [ "$registered_id" = "$id" ] && [ "$registered_key" != "$target" ]; then
      echo "error: capo id $id is already registered to home $registered_key; retire it before assigning $target" >&2
      return 1
    fi
    if [ "$registered_key" = "$target" ] && [ "$registered_id" != "$id" ]; then
      echo "error: capo home $target is already registered to $registered_id" >&2
      return 1
    fi
  done <<< "$REGISTRY_RECORDS"
  return 0
}

join_projects() {
  local out="" project
  for project in "$@"; do
    out="${out}${out:+, }$project"
  done
  printf '%s\n' "$out"
}

write_registry() {  # <id> <home> <projects_csv> <brief>
  local id=$1 home=$2 projects_csv=$3 brief=$4 scope summary tmp today line
  cs_capo_registry_valid_id "$id" || {
    echo "error: capo id must be [A-Za-z0-9._-]+: '$id'" >&2
    return 1
  }
  mkdir -p "$HOST_DIR"
  if [ -L "$REG" ]; then
    echo "error: capo registry is a symlink, not the ordinary file the fleet writes: $REG" >&2
    return 1
  fi
  scope=$(registry_scope_for_brief "$brief")
  summary=$(registry_summary_for_brief "$brief")
  today=$(date +%F)
  tmp="$REG.tmp.$$"
  : > "$tmp"
  # Drop this capo's own rows by LITERAL id match. A regex built from the id
  # would let a dotted id such as `a.b` delete an unrelated `axb` row, and an
  # id-less rewrite would drop a final line that has no trailing newline.
  if [ -f "$REG" ] && [ ! -L "$REG" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if cs_capo_registry_line_is_id "$line" "$id"; then
        continue
      fi
      printf '%s\n' "$line" >> "$tmp"
    done < "$REG"
  fi
  printf -- '- %s - %s (home: %s; scope: %s; projects: %s; added %s)\n' \
    "$id" "$summary" "$home" "$scope" "$projects_csv" "$today" >> "$tmp"
  mv "$tmp" "$REG"
}

# --- project validation and cloning -------------------------------------------

project_mode_main() {  # <project> -> mode word
  local mode
  read -r mode _ <<EOF
$("$SCRIPT_DIR/cs-project-mode.sh" "$1")
EOF
  printf '%s\n' "$mode"
}

project_mode_in_home() {  # <home> <project> -> mode word
  local mode
  read -r mode _ <<EOF
$(CS_ROOT_OVERRIDE='' CS_STATE_OVERRIDE='' CS_DATA_OVERRIDE='' CS_PROJECTS_OVERRIDE='' \
  CS_HOME="$1" "$SCRIPT_DIR/cs-project-mode.sh" "$2")
EOF
  printf '%s\n' "$mode"
}

validate_seed_project() {  # <project>
  local project=$1 src mode url
  src="$PROJECTS/$project"
  [ -d "$src" ] || { echo "error: project $project not found at $src" >&2; return 1; }
  git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "error: project $project is not a git repo" >&2; return 1; }
  mode=$(project_mode_main "$project")
  if [ "$mode" = local-only ]; then
    echo "error: project $project is local-only; capo routes support only made and direct-PR projects" >&2
    return 1
  fi
  url=$(git -C "$src" remote get-url origin 2>/dev/null || true)
  [ -n "$url" ] || { echo "error: project $project is $mode but has no origin remote" >&2; return 1; }
}

clone_project() {  # <project> <home>
  local project=$1 home=$2 src dst url dst_url
  src="$PROJECTS/$project"
  dst="$home/projects/$project"
  url=$(git -C "$src" remote get-url origin 2>/dev/null || true)
  [ -n "$url" ] || { echo "error: project $project has no origin remote" >&2; return 1; }
  if [ -e "$dst" ]; then
    [ -d "$dst" ] || { echo "error: seeded project $project exists at $dst but is not a directory" >&2; return 1; }
    git -C "$dst" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      || { echo "error: seeded project $project at $dst is not a git repo" >&2; return 1; }
    dst_url=$(git -C "$dst" remote get-url origin 2>/dev/null || true)
    [ "$dst_url" = "$url" ] || {
      echo "error: seeded project $project at $dst has origin ${dst_url:-<none>}; expected $url" >&2
      return 1
    }
    return 0
  fi
  git clone --quiet "$url" "$dst"
}

initialize_no_mistakes_project() {  # <home> <project> <created:0|1>
  local home=$1 project=$2 created=$3 mode dst
  mode=$(project_mode_in_home "$home" "$project")
  [ "$mode" = made ] || return 0
  dst="$home/projects/$project"
  if git -C "$dst" remote get-url made >/dev/null 2>&1; then
    return 0
  fi
  if [ "$created" != 1 ]; then
    echo "error: seeded project $project at $dst is not initialized for made; refusing to mutate preexisting clone" >&2
    return 1
  fi
  command -v made >/dev/null 2>&1 || {
    echo "error: made command not found; cannot initialize $project in $home" >&2
    return 1
  }
  # shellcheck disable=SC2119  # both shims deliberately take no args here
  ( cd "$dst" && cs_made_gate_init && cs_made_doctor ) || {
    echo "error: failed to initialize made for $project at $dst" >&2
    return 1
  }
}

sync_project_registry() {  # <home> <project>...
  local home=$1 sub_reg tmp project line today names
  shift
  sub_reg="$home/config/projects.md"
  tmp="$sub_reg.tmp.$$"
  names=$(printf '%s\n' "$@" | awk '{ printf "%s%s", sep, $0; sep="\034" }')
  if [ -f "$sub_reg" ]; then
    awk -v names="$names" '
      BEGIN {
        split(names, a, "\034")
        for (i in a) selected[a[i]]=1
      }
      !($1=="-" && ($2 in selected)) { print }
    ' "$sub_reg" > "$tmp"
  else
    : > "$tmp"
  fi
  today=$(date +%F)
  for project in "$@"; do
    line=$(awk -v n="$project" '$1=="-" && $2==n { print; exit }' "$CONFIG/projects.md" 2>/dev/null || true)
    if [ -z "$line" ]; then
      line="- $project - cloned project (added $today)"
    fi
    printf '%s\n' "$line" >> "$tmp"
  done
  mv "$tmp" "$sub_reg"
}

refuse_populated_projectless_home() {  # <home>
  local home=$1 project_path entries
  for project_path in "$home/projects"/* "$home/projects"/.[!.]* "$home/projects"/..?*; do
    [ -e "$project_path" ] || [ -L "$project_path" ] || continue
    echo "error: cannot seed project-less capo home $home because projects/ contains $(basename "$project_path")" >&2
    echo "error: retire or clean this home first before seeding with --no-projects" >&2
    return 1
  done
  if [ -f "$home/config/projects.md" ]; then
    entries=$(awk '$1 == "-" && $2 != "" { print $2 }' "$home/config/projects.md" || true)
    if [ -n "$entries" ]; then
      echo "error: cannot seed project-less capo home $home because config/projects.md registers: $(printf '%s' "$entries" | tr '\n' ' ')" >&2
      echo "error: retire or clean this home first before seeding with --no-projects" >&2
      return 1
    fi
  fi
  return 0
}

refuse_projectful_projectless_charter() {  # <id> <brief>
  local id=$1 brief=$2 project_clones
  project_clones=$(brief_section_text "$brief" "Project clones")
  if printf '%s\n' "$project_clones" | grep -F 'None. This is a project-less domain' >/dev/null 2>&1 \
    && ! printf '%s\n' "$project_clones" | grep -Eq '^[[:space:]]*-[[:space:]]+'; then
    return 0
  fi
  printf 'error: existing charter brief at %s conflicts with --no-projects\n' "$brief" >&2
  printf 'error: re-scaffold it with cs-brief.sh %s --capo --no-projects or remove the stale brief before seeding\n' "$id" >&2
  return 1
}

# --- transactional seed --------------------------------------------------------

SEED_ROLLBACK_ACTIVE=0
SEED_COMMITTED=0
SEED_HOME=
SEED_HOME_CREATED=0
SEED_BACKUP_DIR=
SEED_CREATED_PROJECTS_FILE=
SEED_PARENT_REG_EXISTED=0
SEED_PARENT_BRIEF=
SEED_PARENT_BRIEF_CREATED=0
SEED_PARENT_BRIEF_DIR_CREATED=0
SEED_SUB_REG_EXISTED=0
SEED_CHARTER_EXISTED=0
SEED_MARKER_EXISTED=0

restore_seed_file() {  # <existed:0|1> <backup> <path>
  if [ "$1" = 1 ]; then
    mkdir -p "$(dirname "$3")"
    cp "$2" "$3" 2>/dev/null || true
  else
    rm -f "$3" 2>/dev/null || true
  fi
}

seed_rollback_target() {  # <target> <label> -> safe absolute target or rc=1
  local target=$1 label=$2 abs_target abs_active abs_root
  [ -n "$target" ] || return 1
  [ "$target" != "/" ] || { echo "REFUSED: unsafe $label rollback target $target" >&2; return 1; }
  abs_target=$(resolved_path "$target")
  abs_active=$(resolved_path "$CS_HOME")
  abs_root=$(resolved_path "$CS_ROOT")
  if [ "$abs_target" = "$abs_active" ] || [ "$abs_target" = "$abs_root" ] \
    || path_is_ancestor_of "$abs_target" "$abs_active" || path_is_ancestor_of "$abs_target" "$abs_root" \
    || path_is_ancestor_of "$abs_active" "$abs_target" || path_is_ancestor_of "$abs_root" "$abs_target"; then
    echo "REFUSED: unsafe $label rollback target $target touches the active home or repo" >&2
    return 1
  fi
  printf '%s\n' "$abs_target"
}

seed_remove_created_home() {  # <home>
  local abs_home
  abs_home=$(seed_rollback_target "$1" "created home") || return 0
  # The created home is a detached worktree of this repo: remove it through
  # git so the repo's worktree registry stays consistent, then prune.
  git -C "$CS_ROOT" worktree remove --force "$abs_home" 2>/dev/null \
    || rm -rf -- "$abs_home" 2>/dev/null || true
  git -C "$CS_ROOT" worktree prune 2>/dev/null || true
}

seed_remove_created_project() {  # <project-path>
  local abs_project abs_projects
  abs_project=$(seed_rollback_target "$1" "created project") || return 0
  abs_projects=$(resolved_path "$SEED_HOME/projects")
  path_is_ancestor_of "$abs_projects" "$abs_project" || {
    echo "REFUSED: unsafe created project rollback target $1 is outside the capo projects directory" >&2
    return 0
  }
  rm -rf -- "$abs_project" 2>/dev/null || true
}

seed_rollback() {
  local project_path
  [ "${SEED_ROLLBACK_ACTIVE:-0}" = 1 ] || return 0
  [ "${SEED_COMMITTED:-0}" = 0 ] || return 0

  if [ -n "${SEED_PARENT_BRIEF:-}" ] && [ "$SEED_PARENT_BRIEF_CREATED" = 1 ]; then
    rm -f "$SEED_PARENT_BRIEF" 2>/dev/null || true
  fi
  if [ -n "${SEED_PARENT_BRIEF:-}" ] && [ "$SEED_PARENT_BRIEF_DIR_CREATED" = 1 ]; then
    rmdir "$(dirname "$SEED_PARENT_BRIEF")" 2>/dev/null || true
  fi

  if [ -n "${SEED_HOME:-}" ] && [ "$SEED_HOME" != "/" ]; then
    if [ "$SEED_HOME_CREATED" = 1 ]; then
      seed_remove_created_home "$SEED_HOME"
    else
      if [ -n "${SEED_CREATED_PROJECTS_FILE:-}" ] && [ -f "$SEED_CREATED_PROJECTS_FILE" ]; then
        while IFS= read -r project_path; do
          [ -n "$project_path" ] || continue
          seed_remove_created_project "$project_path"
        done < "$SEED_CREATED_PROJECTS_FILE"
      fi
      if [ -n "${SEED_BACKUP_DIR:-}" ] && [ -d "$SEED_BACKUP_DIR" ]; then
        restore_seed_file "$SEED_MARKER_EXISTED" "$SEED_BACKUP_DIR/marker" "$SEED_HOME/$MARKER"
        restore_seed_file "$SEED_CHARTER_EXISTED" "$SEED_BACKUP_DIR/charter.md" "$SEED_HOME/config/charter.md"
        restore_seed_file "$SEED_SUB_REG_EXISTED" "$SEED_BACKUP_DIR/sub-projects.md" "$SEED_HOME/config/projects.md"
      fi
    fi
  fi

  if [ -n "${SEED_BACKUP_DIR:-}" ]; then
    restore_seed_file "$SEED_PARENT_REG_EXISTED" "$SEED_BACKUP_DIR/parent-capos.md" "$REG"
    rm -rf -- "$SEED_BACKUP_DIR" 2>/dev/null || true
  fi
}

seed_home() {
  local id=$1 home commit projects_csv project project_dst charter_summary charter_scope
  local no_projects=0 arg
  local filtered=()
  shift
  case "$id" in
    *[!A-Za-z0-9._-]*|'') echo "error: capo id must be [A-Za-z0-9._-]+: '$id'" >&2; return 2 ;;
  esac
  for arg in "$@"; do
    if [ "$arg" = "--no-projects" ]; then
      no_projects=1
    else
      filtered+=("$arg")
    fi
  done
  if [ "${#filtered[@]}" -gt 0 ]; then
    set -- "${filtered[@]}"
  else
    set --
  fi
  if [ "$no_projects" -eq 1 ]; then
    [ $# -eq 0 ] || { echo "error: --no-projects cannot be combined with a project list" >&2; return 1; }
  else
    [ $# -gt 0 ] || { echo "error: a capo needs at least one project, or --no-projects for a project-less home" >&2; return 1; }
  fi

  validate_registry
  for project in "$@"; do
    validate_seed_project "$project"
  done

  home="$CAPOS_ROOT/$id"
  refuse_unsafe_home_path "$home" || return 1
  validate_registry_home_text "$home" || return 1
  validate_home_assignment "$id" "$home" || return 1

  SEED_ROLLBACK_ACTIVE=1
  SEED_COMMITTED=0
  SEED_HOME=
  SEED_HOME_CREATED=0
  SEED_BACKUP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cs-home-seed.XXXXXX")
  SEED_CREATED_PROJECTS_FILE="$SEED_BACKUP_DIR/created-projects"
  : > "$SEED_CREATED_PROJECTS_FILE"
  SEED_PARENT_REG_EXISTED=0
  SEED_PARENT_BRIEF="$DATA/$id/brief.md"
  SEED_PARENT_BRIEF_CREATED=0
  SEED_PARENT_BRIEF_DIR_CREATED=0
  SEED_SUB_REG_EXISTED=0
  SEED_CHARTER_EXISTED=0
  SEED_MARKER_EXISTED=0
  trap seed_rollback EXIT
  if [ -f "$REG" ]; then
    SEED_PARENT_REG_EXISTED=1
    cp "$REG" "$SEED_BACKUP_DIR/parent-capos.md"
  fi

  # Charter brief first: refuse a missing or placeholder charter before any
  # home mutation.
  if [ ! -f "$SEED_PARENT_BRIEF" ]; then
    [ -n "${CS_CAPO_CHARTER:-}" ] || {
      echo "error: no filled capo charter brief at $SEED_PARENT_BRIEF; set CS_CAPO_CHARTER or scaffold one with cs-brief.sh --capo and replace {TASK}" >&2
      return 1
    }
    [ -d "$DATA/$id" ] || SEED_PARENT_BRIEF_DIR_CREATED=1
    if [ "$no_projects" -eq 1 ]; then
      "$SCRIPT_DIR/cs-brief.sh" "$id" --capo --no-projects >/dev/null
    else
      "$SCRIPT_DIR/cs-brief.sh" "$id" --capo "$@" >/dev/null
    fi
    SEED_PARENT_BRIEF_CREATED=1
  fi
  if grep -F '{TASK}' "$SEED_PARENT_BRIEF" >/dev/null 2>&1; then
    echo "error: capo charter brief at $SEED_PARENT_BRIEF still contains {TASK}; fill it before seeding" >&2
    return 1
  fi
  charter_summary=$(registry_summary_for_brief "$SEED_PARENT_BRIEF")
  [ -n "$charter_summary" ] || {
    echo "error: capo charter brief at $SEED_PARENT_BRIEF has an empty Charter section; fill it before seeding" >&2
    return 1
  }
  charter_scope=$(registry_scope_for_brief "$SEED_PARENT_BRIEF")
  [ -n "$charter_scope" ] || {
    echo "error: capo charter brief at $SEED_PARENT_BRIEF has an empty Routing scope section; fill it before seeding" >&2
    return 1
  }

  # Create or adopt the detached-worktree home.
  if [ -e "$home" ]; then
    [ -d "$home" ] || { echo "error: $home exists and is not a directory" >&2; return 1; }
    home_is_worktree_of_root "$home" || {
      echo "error: existing $home is not a git worktree of this consigliere repo; move it aside or retire it first" >&2
      return 1
    }
    SEED_HOME=$(resolved_path "$home")
  else
    commit=$(seed_commit) || { echo "error: cannot resolve a seed commit in $CS_ROOT" >&2; return 1; }
    mkdir -p "$(dirname "$home")"
    SEED_HOME_CREATED=1
    SEED_HOME=$(resolved_path "$home")
    git -C "$CS_ROOT" worktree add --quiet --detach "$home" "$commit" || {
      echo "error: git worktree add failed for $home" >&2
      return 1
    }
  fi
  home=$(cd "$SEED_HOME" && pwd -P)
  SEED_HOME="$home"
  [ -f "$home/AGENTS.md" ] || { echo "error: $home is not a consigliere home (missing AGENTS.md)" >&2; return 1; }
  [ -d "$home/bin" ] || { echo "error: $home is not a consigliere home (missing bin/)" >&2; return 1; }
  if [ "$no_projects" -eq 1 ]; then
    refuse_populated_projectless_home "$home" || return 1
    refuse_projectful_projectless_charter "$id" "$SEED_PARENT_BRIEF" || return 1
  fi

  mkdir -p "$HOST_DIR" "$home/data" "$home/state" "$home/config" "$home/host" "$home/projects"
  # A capo home activates ALWAYS, not only while the boss is away. Its queue
  # rots whenever its parent is busy - measured 8h11m on 2026-08-01 with both
  # capo watchers healthy and 28 wakes undrained. That is also the built-in
  # default now, so this write is explicitness rather than an override; keep it,
  # because a capo's dependence on activation must not rest on a default that
  # some later home could change. bin/cs-activate.sh owns the semantics.
  printf 'always\n' > "$home/host/activation.conf" 2>/dev/null || true
  if [ -f "$home/config/projects.md" ]; then
    SEED_SUB_REG_EXISTED=1
    cp "$home/config/projects.md" "$SEED_BACKUP_DIR/sub-projects.md"
  fi
  if [ -f "$home/config/charter.md" ]; then
    SEED_CHARTER_EXISTED=1
    cp "$home/config/charter.md" "$SEED_BACKUP_DIR/charter.md"
  fi
  if [ -f "$home/$MARKER" ]; then
    SEED_MARKER_EXISTED=1
    cp "$home/$MARKER" "$SEED_BACKUP_DIR/marker"
  fi

  for project in "$@"; do
    project_dst="$home/projects/$project"
    [ -e "$project_dst" ] || printf '%s\n' "$project_dst" >> "$SEED_CREATED_PROJECTS_FILE"
    clone_project "$project" "$home"
  done
  if [ $# -gt 0 ]; then
    sync_project_registry "$home" "$@"
    for project in "$@"; do
      project_dst="$home/projects/$project"
      if grep -Fx -- "$project_dst" "$SEED_CREATED_PROJECTS_FILE" >/dev/null 2>&1; then
        initialize_no_mistakes_project "$home" "$project" 1
      else
        initialize_no_mistakes_project "$home" "$project" 0
      fi
    done
  fi

  cp "$SEED_PARENT_BRIEF" "$home/config/charter.md"
  printf '%s\n' "$id" > "$home/$MARKER"
  cs_inherit_seed "$CS_HOME" "$home" "$id" || {
    echo "error: seed-time inheritance failed for $home" >&2
    return 1
  }

  projects_csv=$(join_projects "$@")
  write_registry "$id" "$home" "$projects_csv" "$SEED_PARENT_BRIEF"
  validate_registry
  SEED_COMMITTED=1
  trap - EXIT
  rm -rf -- "$SEED_BACKUP_DIR"
  printf 'home=%s\n' "$home"
}

# --- bootstrap sweep -----------------------------------------------------------

# Prints the canonical home on rc=0, or the one-line skip reason on rc=1.
sweep_validate_home() {  # <id> <home>
  local id=$1 home=$2 abs_home marker_id
  [ -d "$home" ] || { printf 'home is not a directory'; return 1; }
  abs_home=$(cd "$home" && pwd -P)
  refuse_unsafe_home_path "$abs_home" >/dev/null 2>&1 || { printf 'unsafe home path'; return 1; }
  [ -f "$abs_home/$MARKER" ] || { printf 'not a marked capo home (%s missing)' "$MARKER"; return 1; }
  marker_id=$(cat "$abs_home/$MARKER" 2>/dev/null || true)
  [ "$marker_id" = "$id" ] || { printf 'marked for capo %s, expected %s' "${marker_id:-unknown}" "$id"; return 1; }
  printf '%s' "$abs_home"
}

sweep_ff_home() {  # <id> <home>  - detached-HEAD FF-only advance; CAPO_SYNC lines
  local id=$1 home=$2 target dirty local_rev target_rev before after out
  git -C "$home" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "CAPO_SYNC: capo $id: skipped: not a git worktree"
    return 0
  }
  target=$(seed_commit) || {
    echo "CAPO_SYNC: capo $id: skipped: primary default-branch commit cannot be resolved"
    return 0
  }
  git -C "$home" rev-parse --verify --quiet "$target^{commit}" >/dev/null || {
    echo "CAPO_SYNC: capo $id: skipped: target commit not present in home"
    return 0
  }
  # Tolerate only the gitignored-by-convention identity marker as untracked;
  # anything else dirty means unlanded work this sweep must not disturb.
  dirty=$(git -C "$home" status --porcelain 2>/dev/null \
    | awk -v marker="?? $MARKER" '$0 != marker { print; exit }')
  if [ -n "$dirty" ]; then
    echo "CAPO_SYNC: capo $id: skipped: dirty working tree"
    return 0
  fi
  local_rev=$(git -C "$home" rev-parse HEAD 2>/dev/null) || {
    echo "CAPO_SYNC: capo $id: skipped: cannot read HEAD"
    return 0
  }
  target_rev=$(git -C "$home" rev-parse "$target" 2>/dev/null) || {
    echo "CAPO_SYNC: capo $id: skipped: cannot read target commit"
    return 0
  }
  [ "$local_rev" != "$target_rev" ] || return 0
  if ! git -C "$home" merge-base --is-ancestor HEAD "$target" 2>/dev/null; then
    echo "CAPO_SYNC: capo $id: skipped: diverged from the primary default branch"
    return 0
  fi
  before=$(git -C "$home" rev-parse --short HEAD)
  if ! out=$(git -C "$home" merge --ff-only "$target" 2>&1); then
    echo "CAPO_SYNC: capo $id: skipped: fast-forward failed: $(first_line "$out")"
    return 0
  fi
  after=$(git -C "$home" rev-parse --short HEAD)
  echo "CAPO_SYNC: capo $id: updated $before..$after"
}

# Converge host/activation.conf for a home seeded before per-home activation
# existed. A seed-time-only default never reaches an existing home, whose
# absent value resolves to afk-only and prevents self-started turns.
# Fill ONLY absence: any present value, including a symlink to externally
# managed config, is a deliberate choice this sweep must not overwrite.
sweep_activation_home() {  # <id> <home>  - CAPO_SYNC line only when it acts
  local id=$1 home=$2
  local activation="$home/host/activation.conf"
  # _cs_inherit_dir_safe may mkdir its argument, so a symlinked host/ (which
  # would write outside the capo home) is refused before anything is created.
  _cs_inherit_dir_safe "$home/host" || {
    echo "CAPO_SYNC: capo $id: skipped: unsafe host/ for activation"
    return 0
  }
  [ ! -e "$activation" ] && [ ! -L "$activation" ] || return 0
  if (set -C; printf 'always\n' > "$activation") 2>/dev/null; then
    echo "CAPO_SYNC: capo $id: activation set to always (was unset)"
  elif [ -e "$activation" ] || [ -L "$activation" ]; then
    return 0
  else
    echo "CAPO_SYNC: capo $id: skipped: cannot write host/activation.conf"
  fi
}

# One registry row's convergence. This is the loop body of sweep_sync, lifted
# into a function so it can be bracketed by one elapsed-time record per capo:
# each former `continue` is a `return 0` here and means exactly what it did, and
# the already-converged set it consults across rows is the one piece of state
# that has to outlive a single call.
sweep_sync_home() {  # <status> <id> <home> <raw>
  local status=$1 id=$2 home=$3 raw=$4 abs_home result
  if [ "$status" != ok ]; then
    echo "CAPO_SYNC: skipped: malformed capo registry entry: $raw"
    return 0
  fi
  if result=$(sweep_validate_home "$id" "$home"); then
    abs_home=$result
  else
    echo "CAPO_SYNC: capo $id: skipped: ${result:-unsafe home}"
    return 0
  fi
  case " $SWEEP_SYNC_SEEN " in
    *" $abs_home "*) return 0 ;;
  esac
  SWEEP_SYNC_SEEN="$SWEEP_SYNC_SEEN $abs_home"
  sweep_ff_home "$id" "$abs_home"
  sweep_activation_home "$id" "$abs_home"
  cs_inherit_converge "$CS_HOME" "$abs_home" "$id" || {
    echo "CAPO_SYNC: capo $id: skipped: inheritance failed"
  }
}

sweep_sync() {
  local status id home scope raw
  load_registry_records || {
    echo "CAPO_SYNC: skipped: $REGISTRY_RECORDS_ERROR"
    return 0
  }
  [ -n "$REGISTRY_RECORDS" ] || return 0
  SWEEP_SYNC_SEEN=""
  while IFS=$'\t' read -r status id home scope raw; do
    cs_timed capo-sync "$id" sweep_sync_home "$status" "$id" "$home" "$raw"
  done <<< "$REGISTRY_RECORDS"
}

sweep_probe_agent() {  # <pane> -> alive|dead|unknown
  local pane=$1 out
  if ! cs_herdr_pane_exists "$pane"; then
    # Server reachability was proven by the caller, so a missing pane is a
    # confident dead reading (the agent has no endpoint), not an error.
    printf 'dead'
    return 0
  fi
  out=$(cs_herdr agent get "$pane" 2>/dev/null) || { printf 'unknown'; return 0; }
  if printf '%s' "$out" | jq -e '.result.agent.agent // empty | select(. != "")' >/dev/null 2>&1; then
    printf 'alive'
  else
    printf 'dead'
  fi
}

# One capo's liveness probe and, when it is dead, its respawn. Lifted out of
# sweep_liveness's loop for the same reason sweep_sync_home was: each former
# `continue` is a `return 0` with the same meaning, and the whole body is now one
# timed unit, so a slow probe or a slow respawn names the capo it belongs to.
sweep_liveness_meta() {  # <meta> <id> <herdr-ok>
  local meta=$1 id=$2 herdr_ok=$3 pane home verdict out meta_backup
  pane=$(grep '^pane=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  # A meta with no recorded pane is left to the recovery path (AGENTS.md
  # section 5 / capo-provisioning); there is no endpoint here to probe. It is
  # reported rather than skipped silently so the accounting stays complete.
  if [ -z "$pane" ]; then
    echo "CAPO_LIVENESS: capo $id: skipped: local record has no endpoint (recover via capo-provisioning)"
    return 0
  fi
  if [ "$herdr_ok" != 1 ]; then
    echo "CAPO_LIVENESS: capo $id: skipped: herdr unreachable"
    return 0
  fi
  home=$(grep '^home=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$home" ] || home=$(cs_capo_registry_field "$REG" "$id" home 2>/dev/null || true)
  verdict=$(sweep_probe_agent "$pane")
  case "$verdict" in
    alive) ;;
    dead)
      if [ -z "$home" ]; then
        echo "CAPO_LIVENESS: capo $id: skipped: dead endpoint but no recorded home"
        return 0
      fi
      cs_herdr_pane_close "$pane" >/dev/null 2>&1 || true
      # cs-spawn refuses a pre-existing meta, so move the stale record
      # aside and restore it if the respawn fails.
      meta_backup="$meta.pre-respawn"
      mv "$meta" "$meta_backup"
      if out=$("$SPAWN_BIN" "$id" "$home" --capo 2>&1); then
        rm -f "$meta_backup"
      else
        mv "$meta_backup" "$meta" 2>/dev/null || true
        echo "CAPO_LIVENESS: capo $id: respawn failed: $(first_line "$out")"
      fi
      ;;
    *)
      echo "CAPO_LIVENESS: capo $id: skipped: liveness probe inconclusive"
      ;;
  esac
  return 0
}

sweep_liveness() {
  local meta id herdr_ok=1
  [ -d "$STATE" ] || return 0
  cs_herdr_require >/dev/null 2>&1 || herdr_ok=0
  if [ "$herdr_ok" = 1 ]; then
    cs_herdr status --json >/dev/null 2>&1 || herdr_ok=0
  fi
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=capo$' "$meta" 2>/dev/null || continue
    id=$(basename "$meta" .meta)
    cs_timed capo-liveness "$id" sweep_liveness_meta "$meta" "$id" "$herdr_ok"
  done
  return 0
}

sweep() {
  cs_timed capo-sync '' sweep_sync
  cs_timed capo-liveness '' sweep_liveness
  return 0
}

# --- entry ---------------------------------------------------------------------

case "${1:-}" in
  validate)
    [ $# -eq 1 ] || { usage >&2; exit 1; }
    validate_registry
    ;;
  --sweep)
    [ $# -eq 1 ] || { usage >&2; exit 1; }
    sweep
    ;;
  *)
    [ $# -ge 2 ] || { usage >&2; exit 1; }
    seed_home "$@"
    ;;
esac
