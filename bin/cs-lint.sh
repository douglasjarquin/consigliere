#!/usr/bin/env bash
# cs-lint.sh - the single owner of consigliere's lint definition.
#
# Runs ShellCheck over consigliere's tracked shell scripts at ShellCheck's
# default severity (info, warning, error - the levels CI fails on), and on its
# default (no explicit-path) path also runs bin/cs-lint-workflows.sh so a
# self-broken ci.yml fails before merge. The shell lint command, the file set,
# the config, AND the pinned ShellCheck version live here and ONLY here, so the
# gates cannot drift apart: every caller invokes this script with no arguments.
#   - CI:       .github/workflows/ci.yml installs the versions this script and
#               cs-lint-workflows.sh print via `--required-version`, then runs
#               `bin/cs-lint.sh`.
#   - Local:    developers and any pre-push gate run `bin/cs-lint.sh`, so local
#               runs the SAME ShellCheck rule set as CI, over the files this
#               branch changed; `CI=true bin/cs-lint.sh` reproduces CI's full-set
#               run exactly. No second place spells out the lint command, the
#               file set, or the version.
#
# Version parity: an unpinned CI ShellCheck floats with the runner image, and
# ShellCheck's rule set changes between releases (e.g. SC2015 was retired in
# 0.11.0), so a floating CI ShellCheck can reject a finding a newer local one no
# longer emits, or vice versa. This script pins one exact version
# (REQUIRED_SHELLCHECK) and asserts the resolved `shellcheck` matches it, so CI
# and local run the identical rule set. No severity downgrade and no blanket
# exclude of checks - every finding at default severity is enforced.
# The local == CI parity contract is asserted by tests/cs-ci-contract.test.sh.
#
# Local runs lint only the canonical-set files this branch changed. Consigliere
# runs several lanes at once by design, and linting the whole canonical set in
# every lane made concurrent runs contend for the machine (two lanes together
# spiked one Mac to 190% CPU and 8.58 load) even though each run finished fast.
# The change set comes from plain local git - the merge-base with origin/main
# plus uncommitted edits - so the selection costs no network call. The libraries
# those files source ride along, and so do the canonical files that source them,
# so a narrowed run reports every finding a full-set run blames on the files this
# branch changed.
# CI ALWAYS LINTS THE FULL CANONICAL SET, and so does the default branch, and so
# does any run whose change set cannot be determined: coverage never depends on
# a local diff. The selection is a local-speed optimization only, never a weaker
# gate.
#
# Usage:
#   cs-lint.sh                    lint the canonical-set files changed since the
#                                  merge-base with origin/main, including
#                                  uncommitted edits; the full canonical set in
#                                  CI, on the default branch, or whenever the
#                                  change set cannot be determined
#   cs-lint.sh <path>...          lint only the given paths with the same config,
#                                  bypassing the change selection entirely
#                                  (developer convenience; the gates never pass args)
#   cs-lint.sh --required-version print the pinned ShellCheck version and exit
#                                  (CI reads this to install the exact same one)
#   cs-lint.sh --canonical-set    print the canonical file set, one path per line,
#                                  and exit (so a caller never re-spells the globs)
#
# Exit status is ShellCheck's own on a lint run, so a caller (CI or a gate) fails
# exactly when ShellCheck reports a finding; a version mismatch or a missing
# ShellCheck fails before linting with a distinct message. A run whose change set
# holds no canonical-set file lints nothing and exits 0.
set -eu

# The single source of the pinned ShellCheck version. Bump here and CI follows
# automatically via `--required-version`; the contract test reads it the same way.
REQUIRED_SHELLCHECK=0.11.0

# The default branch, and the ref the change selection measures against.
DEFAULT_BRANCH=main
BASE_REF="origin/$DEFAULT_BRANCH"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# Canonical file set: the ONE authoritative definition. Callers reference this
# script; they never re-spell these globs. consigliere keeps all shell under
# bin/ and tests/ (Python helpers such as bin/*.py are not shell and are out of
# scope); tests/*.sh covers both *.test.sh files and shared *-helpers.sh / lib.sh.
# The change selection below never widens this set; it only narrows it.
# The globs are kept as patterns because the set has to answer two questions: what
# is on disk now (their expansion) and whether a path a branch deleted was one of
# ours (no expansion can match a file that is gone).
canonical_globs=('bin/*.sh' 'tests/*.sh' 'scripts/ci/*.sh' 'mise-tasks/dev/*')
canonical=()
for glob in "${canonical_globs[@]}"; do
  # shellcheck disable=SC2086  # unquoted on purpose: $glob is a pattern to expand
  for path in $glob; do
    # A glob that matches nothing (no nullglob set) leaves $path as the literal,
    # non-existent pattern string; skip it rather than adding a bogus "file".
    [ -e "$path" ] || continue
    canonical+=("$path")
  done
done

cs_is_canonical() {
  local glob
  for glob in "${canonical_globs[@]}"; do
    # shellcheck disable=SC2254  # unquoted on purpose: $glob is a case pattern
    case "$1" in
      $glob) return 0 ;;
    esac
  done
  return 1
}

# Both queries answer before the ShellCheck pin is enforced, so a caller can read
# what this script owns without ShellCheck installed: CI reads the version to
# install that exact build, and the contract test reads the file set instead of
# re-spelling the globs.
if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_SHELLCHECK"
  exit 0
fi
if [ "${1:-}" = "--canonical-set" ]; then
  printf '%s\n' "${canonical[@]}"
  exit 0
fi

# Default no-args lint also validates GitHub workflows. Explicit paths stay a
# ShellCheck-only override so callers can target one shell root.
cs_lint_run_workflows() {
  [ "$EXPLICIT_PATHS" -eq 0 ] || return 0
  "$ROOT/bin/cs-lint-workflows.sh"
}

EXPLICIT_PATHS=0
if [ "$#" -gt 0 ]; then
  EXPLICIT_PATHS=1
fi

# Enforce the pin so local and CI resolve the identical rule set.
if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'cs-lint.sh: ShellCheck not found; install ShellCheck %s with bin/cs-install-shellcheck.sh <destination-directory> and put that directory on PATH.\n' \
    "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi
unset SHELLCHECK_OPTS
resolved=$(shellcheck --version | awk '/^version:/ {print $2; exit}')
# Log the resolved version to stderr so both CI and local runs record it.
printf 'cs-lint.sh: ShellCheck %s (pinned %s)\n' "$resolved" "$REQUIRED_SHELLCHECK" >&2
if [ "$resolved" != "$REQUIRED_SHELLCHECK" ]; then
  printf 'cs-lint.sh: ShellCheck %s required for CI parity, found %s. Install %s with bin/cs-install-shellcheck.sh <destination-directory>.\n' \
    "$REQUIRED_SHELLCHECK" "$resolved" "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi

# Explicit paths bypass the change selection: lint exactly what was named.
if [ "$EXPLICIT_PATHS" -eq 1 ]; then
  exec shellcheck --norc "$@"
fi

# Decide whether this run must lint the whole canonical set. Each reason is a
# case where a local diff cannot stand in for full coverage: CI is the gate of
# record, the default branch has no branch diff to speak of, a repository
# toplevel other than this directory puts git's paths on a different base than
# the canonical globs, and a missing merge-base means the change set is unknown.
# An undeterminable change set always falls back to the full set, never to
# nothing.
full_reason=
if [ "${GITHUB_ACTIONS:-}" = true ] || [ "${CI:-}" = true ]; then
  full_reason=CI
elif [ "$(git branch --show-current 2>/dev/null || true)" = "$DEFAULT_BRANCH" ]; then
  full_reason="on the default branch $DEFAULT_BRANCH"
elif ! toplevel=$(git rev-parse --show-toplevel 2>/dev/null) ||
  [ "$(cd "$toplevel" 2>/dev/null && pwd -P || true)" != "$(pwd -P)" ]; then
  # `git diff --name-only` names paths from the repository toplevel while the
  # canonical globs are relative to this directory, so the two share a base only
  # when they are the same directory - a checkout nested inside another repo
  # would otherwise intersect to nothing and silently lint nothing. Compared
  # physically, because a symlinked component (macOS /tmp -> /private/tmp) is
  # one directory to git and two different strings to the shell.
  full_reason="the repository toplevel is not $ROOT"
else
  # Plain local git only: no fetch, no remote call. An unknown BASE_REF, a
  # shallow clone, or an unrelated history leaves this empty.
  merge_base=$(git merge-base HEAD "$BASE_REF" 2>/dev/null || true)
  [ -n "$merge_base" ] || full_reason="no merge-base with $BASE_REF"
fi

# Every sort and comm below runs under LC_ALL=C. `comm` compares in the ambient
# collation, so a byte-sorted list fed to a comm running under a UTF-8 locale is
# "unsorted" to it and matches get silently dropped - on this repo that alone
# lost bin/cs-lint.sh from its own change set, because en_US.UTF-8 orders
# "bin/..." before "README.md" while C orders it after.

# The branch's changed files: everything that differs from the merge-base in the
# working tree (committed, staged, and unstaged alike), plus untracked files, so
# a brand-new script is linted before it is ever committed. Deletions are kept
# apart rather than discarded: ShellCheck cannot read a file that is gone, but
# deleting a library is a change the files that still source it are judged on, so
# a deleted path has to reach the reverse pass below. `--no-renames` is what makes
# that hold for a rename: with rename detection on, git reports a move as one R
# entry naming only the destination, so the path this branch moved away from would
# reach neither query and a consumer left pointing at it would never be linted.
# Each query's exit status is checked on its own, because a pipeline into `sort`
# would report `sort`'s success and turn a failed query into an empty change set.
changed=
deleted=
if [ -z "$full_reason" ]; then
  if tracked_changed=$(git diff --no-renames --name-only --diff-filter=d "$merge_base" --) &&
    tracked_deleted=$(git diff --no-renames --name-only --diff-filter=D "$merge_base" --) &&
    untracked=$(git ls-files --others --exclude-standard --); then
    changed=$(printf '%s\n%s\n' "$tracked_changed" "$untracked" | LC_ALL=C sort -u)
    deleted=$(printf '%s\n' "$tracked_deleted" | LC_ALL=C sort -u)
  else
    full_reason="the change set could not be determined"
  fi
fi

if [ -n "$full_reason" ]; then
  printf 'cs-lint.sh: linting the full canonical set (%s)\n' "$full_reason" >&2
  cs_lint_run_workflows || exit $?
  exec shellcheck --norc "${canonical[@]}"
fi

# Intersect with the canonical set, so the selection can only ever be a subset of
# what a full run lints.
canonical_sorted=$(printf '%s\n' "${canonical[@]}" | LC_ALL=C sort -u)
selected=()
while IFS= read -r path; do
  [ -n "$path" ] || continue
  selected+=("$path")
done < <(printf '%s\n' "$canonical_sorted" | LC_ALL=C comm -12 - <(printf '%s\n' "$changed"))
deleted_canonical=$(
  printf '%s\n' "$deleted" | while IFS= read -r path; do
    [ -n "$path" ] || continue
    if cs_is_canonical "$path"; then printf '%s\n' "$path"; fi
  done | LC_ALL=C sort -u
)

if [ "${#selected[@]}" -eq 0 ] && [ -z "$deleted_canonical" ]; then
  printf 'cs-lint.sh: no canonical-set file changed since %s; nothing to lint.\n' \
    "$BASE_REF" >&2
  cs_lint_run_workflows || exit $?
  exit 0
fi

# ShellCheck follows a `.` line only when the sourced file is an input too, so a
# narrowed input set changes what it reports in BOTH directions:
#   - forward: a sourced library missing from the inputs turns a line the full
#     run resolves silently into SC1091 ("was not specified as input"), a finding
#     created purely by narrowing;
#   - reverse: a finding caused by a changed library is reported in the file that
#     sources it, not in the library, so editing a library out from under its
#     consumers (dropping a variable they read, say) is invisible unless those
#     consumers are inputs as well - green locally, red in CI one push later.
# The graph is the repo's own `# shellcheck source=` directives, nothing else.
# Reading the source lines themselves would mean reimplementing ShellCheck's path
# resolver here and keeping the copy honest forever; the directives are already
# the declaration ShellCheck itself reads, so they are the one place a source
# edge is written down. That makes the graph exactly as complete as the
# directives are, which is why tests/cs-ci-contract.test.sh fails the build when a
# source site in the canonical set has no directive. Targets outside the canonical
# set (/dev/null, anything unshipped) fall away at the intersection in cs_close:
# the full run does not have them as input either, so parity means leaving them
# out.
canonical_files=()
while IFS= read -r file; do
  [ -n "$file" ] && [ -f "$file" ] || continue
  canonical_files+=("$file")
done <<<"$canonical_sorted"

edges=$(
  awk '
    /^[[:space:]]*#[[:space:]]*shellcheck[[:space:]]+source=/ {
      target = $0
      sub(/^.*source=/, "", target)
      sub(/[[:space:]].*$/, "", target)
      if (target != "") print FILENAME "\t" target
    }
  ' "${canonical_files[@]}"
)

# cs_close <dependents|sources> <file list> - grow a newline-separated file list
# to its transitive closure over that edge direction, staying inside the
# canonical set. Growth is monotonic and bounded by the canonical set, so a
# source cycle simply runs the frontier dry.
cs_close() {
  local direction=$1 closed=$2 frontier=$2 next
  while [ -n "$frontier" ]; do
    next=$(
      awk -F'\t' -v dir="$direction" '
        NR == FNR { if ($0 != "") want[$0] = 1; next }
        dir == "sources" { if ($1 in want) print $2; next }
        { if ($2 in want) print $1 }
      ' <(printf '%s\n' "$frontier") <(printf '%s\n' "$edges") |
        LC_ALL=C sort -u |
        LC_ALL=C comm -12 - <(printf '%s\n' "$canonical_sorted") |
        LC_ALL=C comm -23 - <(printf '%s\n' "$closed")
    )
    [ -n "$next" ] || break
    closed=$(printf '%s\n%s\n' "$closed" "$next" | LC_ALL=C sort -u)
    frontier=$next
  done
  printf '%s\n' "$closed"
}

# Dependents first and only of the changed files, then sources of everything: a
# finding can only be created by a change, so the files that source a change need
# linting, while an unchanged library pulled in for its definitions does not drag
# in its own unrelated consumers. Sourcing is transitive, so a dependent's
# dependent sees the change too and the reverse pass runs to a fixpoint; the
# forward pass then keeps every input SC1091-clean. Deleted paths seed the reverse
# pass alongside the surviving changes: a consumer left sourcing a library this
# branch removed is exactly what a full run fails on, and cs_close intersects only
# what it discovers with the canonical set, never the seed, so what the seed added
# has to be taken back out by hand. What comes out is only what is really gone,
# tested against the working tree rather than against the delete query: a path can
# be reported deleted and still sit on disk (removed from the index, then written
# back unstaged), and such a file is both changed and lintable, so dropping it on
# the delete query's word alone would hide brand-new content from the gate.
seed=$(
  {
    if [ "${#selected[@]}" -gt 0 ]; then printf '%s\n' "${selected[@]}"; fi
    printf '%s\n' "$deleted_canonical"
  } | LC_ALL=C sort -u
)
gone=$(
  printf '%s\n' "$deleted_canonical" | while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ ! -f "$path" ]; then printf '%s\n' "$path"; fi
  done | LC_ALL=C sort -u
)
inputs=$(cs_close dependents "$seed")
inputs=$(cs_close sources "$inputs")
inputs=$(printf '%s\n' "$inputs" | LC_ALL=C comm -23 - <(printf '%s\n' "$gone"))

lint_set=()
while IFS= read -r path; do
  [ -n "$path" ] || continue
  lint_set+=("$path")
done <<<"$inputs"

if [ "${#lint_set[@]}" -eq 0 ]; then
  printf 'cs-lint.sh: only deleted canonical files changed since %s; nothing to lint.\n' \
    "$BASE_REF" >&2
  cs_lint_run_workflows || exit $?
  exit 0
fi

printf 'cs-lint.sh: linting %s changed file(s) plus %s source-linked file(s) since %s (CI lints the full set)\n' \
  "${#selected[@]}" "$((${#lint_set[@]} - ${#selected[@]}))" "$BASE_REF" >&2
cs_lint_run_workflows || exit $?
exec shellcheck --norc "${lint_set[@]}"
