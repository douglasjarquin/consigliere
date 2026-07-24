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
#               runs the SAME ShellCheck rule set as CI. There is no second place
#               that spells out the shellcheck command, file set, or version.
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
# Usage:
#   cs-lint.sh                    lint the canonical file set (what every gate runs)
#   cs-lint.sh <path>...          lint only the given paths with the same config
#                                  (developer convenience; the gates never pass args)
#   cs-lint.sh --required-version print the pinned ShellCheck version and exit
#                                  (CI reads this to install the exact same one)
#
# Exit status is ShellCheck's own on a lint run, so a caller (CI or a gate) fails
# exactly when ShellCheck reports a finding; a version mismatch or a missing
# ShellCheck fails before linting with a distinct message.
set -eu

# The single source of the pinned ShellCheck version. Bump here and CI follows
# automatically via `--required-version`; the contract test reads it the same way.
REQUIRED_SHELLCHECK=0.11.0

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

if [ "$#" -gt 0 ]; then
  exec shellcheck --norc "$@"
fi

# Canonical file set: the ONE authoritative definition. Callers reference this
# script; they never re-spell these globs. consigliere keeps all shell under
# bin/ and tests/ (Python helpers such as bin/*.py are not shell and are out of
# scope); tests/*.sh covers both *.test.sh files and shared *-helpers.sh / lib.sh.
exec shellcheck --norc bin/*.sh tests/*.sh
