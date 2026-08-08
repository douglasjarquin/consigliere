#!/usr/bin/env bash
# cs-lint.sh - the single owner of consigliere's shell-lint definition.
#
# Runs ShellCheck over consigliere's tracked shell scripts at ShellCheck's
# default severity (info, warning, error - the levels CI fails on). The lint
# command, the file set, the config, AND the pinned ShellCheck version live here
# and ONLY here, so the gates cannot drift apart: every caller invokes this
# script with no arguments.
#   - CI:       .github/workflows/ci.yml installs the version this script prints
#               via `--required-version`, then runs `bin/cs-lint.sh`.
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
# those files source ride along, so a narrowed run reports exactly what a
# full-set run reports.
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

# Expose the pinned version without needing ShellCheck installed, so CI can read
# it to install the exact same build before any lint runs.
if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_SHELLCHECK"
  exit 0
fi

# Enforce the pin so local and CI resolve the identical rule set.
if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'cs-lint.sh: ShellCheck not found; install ShellCheck %s for CI parity.\n' \
    "$REQUIRED_SHELLCHECK" >&2
  exit 127
fi
unset SHELLCHECK_OPTS
resolved=$(shellcheck --version | awk '/^version:/ {print $2; exit}')
# Log the resolved version to stderr so both CI and local runs record it.
printf 'cs-lint.sh: ShellCheck %s (pinned %s)\n' "$resolved" "$REQUIRED_SHELLCHECK" >&2
if [ "$resolved" != "$REQUIRED_SHELLCHECK" ]; then
  printf 'cs-lint.sh: ShellCheck %s required for CI parity, found %s. Install %s.\n' \
    "$REQUIRED_SHELLCHECK" "$resolved" "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi

# Explicit paths bypass the change selection: lint exactly what was named.
if [ "$#" -gt 0 ]; then
  exec shellcheck --norc "$@"
fi

# Canonical file set: the ONE authoritative definition. Callers reference this
# script; they never re-spell these globs. consigliere keeps all shell under
# bin/ and tests/ (Python helpers such as bin/*.py are not shell and are out of
# scope); tests/*.sh covers both *.test.sh files and shared *-helpers.sh / lib.sh.
# The change selection below never widens this set; it only narrows it.
canonical=(bin/*.sh tests/*.sh)

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
# a brand-new script is linted before it is ever committed. Deletions are
# dropped, since ShellCheck cannot read a file that is gone. Each query's exit
# status is checked on its own, because a pipeline into `sort` would report
# `sort`'s success and turn a failed query into an empty change set.
changed=
if [ -z "$full_reason" ]; then
  if tracked_changed=$(git diff --name-only --diff-filter=d "$merge_base" --) &&
    untracked=$(git ls-files --others --exclude-standard --); then
    changed=$(printf '%s\n%s\n' "$tracked_changed" "$untracked" | LC_ALL=C sort -u)
  else
    full_reason="the change set could not be determined"
  fi
fi

if [ -n "$full_reason" ]; then
  printf 'cs-lint.sh: linting the full canonical set (%s)\n' "$full_reason" >&2
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

if [ "${#selected[@]}" -eq 0 ]; then
  printf 'cs-lint.sh: no canonical-set file changed since %s; nothing to lint.\n' \
    "$BASE_REF" >&2
  exit 0
fi

# A sourced library must be in the input list or ShellCheck reports SC1091
# ("was not specified as input") against a `.` line that a full-set run resolves
# silently - a finding created purely by narrowing the input, not by the code.
# Every source in this repo declares its target with a `# shellcheck source=`
# directive, so following those directives to their transitive closure makes a
# narrowed run report exactly what the full run reports. Sources outside the
# canonical set (/dev/null, anything unshipped) are dropped: the full run does
# not have them as input either, so keeping the parity means leaving them out.
inputs=$(printf '%s\n' "${selected[@]}" | LC_ALL=C sort -u)
frontier=$inputs
while [ -n "$frontier" ]; do
  deps=$(
    printf '%s\n' "$frontier" | while IFS= read -r file; do
      [ -f "$file" ] || continue
      sed -n 's/^[[:space:]]*#[[:space:]]*shellcheck source=\([^[:space:]]*\).*/\1/p' "$file"
    done | LC_ALL=C sort -u |
      LC_ALL=C comm -12 - <(printf '%s\n' "$canonical_sorted") |
      LC_ALL=C comm -23 - <(printf '%s\n' "$inputs")
  )
  [ -n "$deps" ] || break
  inputs=$(printf '%s\n%s\n' "$inputs" "$deps" | LC_ALL=C sort -u)
  frontier=$deps
done

lint_set=()
while IFS= read -r path; do
  [ -n "$path" ] || continue
  lint_set+=("$path")
done <<<"$inputs"

printf 'cs-lint.sh: linting %s changed file(s) plus %s sourced dependency file(s) since %s (CI lints the full set)\n' \
  "${#selected[@]}" "$((${#lint_set[@]} - ${#selected[@]}))" "$BASE_REF" >&2
exec shellcheck --norc "${lint_set[@]}"
