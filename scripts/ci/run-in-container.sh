#!/usr/bin/env bash
# run-in-container.sh - build (using Docker's own layer cache) and run a
# command inside the dev container. Adapted from niceuptime's own
# scripts/ci/run-in-dev-container.sh wrapper pattern, kept runner-agnostic
# (docker compose, not GitHub Actions' native `container:` job key) so the
# same CI steps work unchanged today on GitHub-hosted ubuntu-latest and
# later on any self-hosted runner.
#
# Usage:
#   scripts/ci/run-in-container.sh <command...>
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

die() {
  printf 'run-in-container.sh: %s\n' "$*" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || die "docker is required but not found on PATH"
docker compose version >/dev/null 2>&1 || die "docker compose is required but not found (docker present, compose plugin missing)"

docker compose build dev
exec docker compose run --rm dev "$@"
