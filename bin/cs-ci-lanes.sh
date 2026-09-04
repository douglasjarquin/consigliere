#!/usr/bin/env bash
# cs-ci-lanes.sh - decide which CI lanes a change actually needs to run.
#
# The single owner of the map from changed paths to CI lanes. The workflow calls
# this script and gates each lane on its output, so the mapping is one testable
# thing in the repo rather than a set of `paths:` globs duplicated per job in
# YAML. tests/cs-ci-lanes.test.sh exercises it hermetically.
#
# Usage:
#   cs-ci-lanes.sh <base-ref> <head-ref>   diff two refs and decide
#   cs-ci-lanes.sh --paths-from <file>     decide from a changed-path list
#                                          ("-" reads stdin, one path per line)
#   cs-ci-lanes.sh --help
#
# Prints one `<lane>=true|false` line per lane to stdout, ready to append to
# GITHUB_OUTPUT, and a human-readable explanation to stderr for the CI log.
#
# WHY EACH LANE HAS THE TRIGGERS IT HAS:
#   lint      cs-lint.sh's file set is bin/*.sh plus tests/*.sh; nothing else can
#             change its verdict.
#   coverage  the lane partition is a property of tests/*.test.sh and the runner
#             that categorizes them.
#   portable  the hermetic suite reads more of the repo than bin/ and tests/: the
#             CI contract test asserts the pinned herdr version in docs/herdr.md,
#             the rundown test asserts skills/rundown/SKILL.md and its README
#             inventory entry, and the decision-hold test copies .tasks.toml. All
#             of those are therefore triggers.
#   herdr     the real-herdr suite drives bin/ through tests/, and the install and
#             cleanup steps live in the workflow.
#   docker    the real-docker lane exercises the dev-tools suite itself; nothing
#             outside mise.toml, mise-tasks/dev/*, docker/*, docker-compose.yml,
#             and scripts/ci/* can change its verdict.
#   web       the Astro docs site under web/, plus the mise toolchain pin that
#             selects Node and Aube for it.
#
# Repo invariants are deliberately NOT a lane here: any commit at all can track a
# boss-private path or flatten a tracked symlink, so that job stays unconditional
# in the workflow. Never move it behind a filter.
#
# FAIL-OPEN BY DESIGN: when the change set cannot be determined (an unresolvable,
# missing, or all-zero base or head - a force-push, a fresh branch, a shallow
# clone), every lane is reported true. A wrongly-skipped required lane is a silent
# false green; a wrongly-run lane only costs minutes.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LANES='lint coverage portable herdr docker web'

usage() {
  awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
}

note() {
  printf 'cs-ci-lanes: %s\n' "$*" >&2
}

# emit_all <true|false> - print every lane with the same value.
emit_all() {
  local lane
  for lane in $LANES; do
    printf '%s=%s\n' "$lane" "$1"
  done
}

fail_open() {
  note "$1; running every lane"
  emit_all true
  exit 0
}

if [ "$#" -eq 0 ]; then
  printf 'usage: cs-ci-lanes.sh <base-ref> <head-ref> | --paths-from <file|->\n' >&2
  exit 2
fi

# An EMPTY ref argument is not a usage error: CI legitimately passes one when the
# event carries no base sha, and that case must fail open rather than exit 2 and
# take the whole run down with it.
PATHS_FILE=
case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
  --paths-from)
    PATHS_FILE=${2:?usage: cs-ci-lanes.sh --paths-from <file|->}
    ;;
  -?*)
    printf 'cs-ci-lanes.sh: unknown option "%s" (see --help)\n' "$1" >&2
    exit 2
    ;;
esac

# --- collect the changed paths ------------------------------------------------

if [ -n "$PATHS_FILE" ]; then
  if [ "$PATHS_FILE" = - ]; then
    changed=$(cat)
  else
    [ -f "$PATHS_FILE" ] || fail_open "path list \"$PATHS_FILE\" does not exist"
    changed=$(cat "$PATHS_FILE")
  fi
else
  BASE=${1:-}
  HEAD=${2:-}
  [ -n "$BASE" ] && [ -n "$HEAD" ] || fail_open 'base or head ref is empty'
  # An all-zero sha is git's "no such commit": a branch's first push, or a ref
  # that was deleted and recreated.
  case "$BASE" in *[!0]*) : ;; *) fail_open "base ref \"$BASE\" is the all-zero sha" ;; esac
  git -C "$ROOT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null ||
    fail_open "base ref \"$BASE\" is not in this clone"
  git -C "$ROOT" rev-parse --verify --quiet "$HEAD^{commit}" >/dev/null ||
    fail_open "head ref \"$HEAD\" is not in this clone"
  changed=$(git -C "$ROOT" diff --name-only "$BASE" "$HEAD") ||
    fail_open "could not diff \"$BASE\"..\"$HEAD\""
fi

if [ -z "$changed" ]; then
  note 'no changed paths; every filtered lane is skipped'
  emit_all false
  exit 0
fi

# --- map paths to lanes -------------------------------------------------------

lint=false
coverage=false
portable=false
herdr=false
docker=false
web=false

while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    # A workflow change can move every lane, including the docs-site job.
    .github/workflows/*)
      lint=true
      coverage=true
      portable=true
      herdr=true
      docker=true
      web=true
      ;;
    # Shell changes move the shell lanes, not the docs site.
    bin/* | tests/*)
      lint=true
      coverage=true
      portable=true
      herdr=true
      ;;
    # Content the hermetic suite asserts on, but that no shell lane reads.
    skills/* | docs/* | README.md | .tasks.toml)
      portable=true
      ;;
    grokbot/*)
      portable=true
      ;;
    mise.toml | mise.lock)
      lint=true
      portable=true
      docker=true
      web=true
      ;;
    mise-tasks/* | docker/* | docker-compose.yml | scripts/ci/*)
      lint=true
      portable=true
      docker=true
      ;;
    web/*)
      web=true
      ;;
  esac
done <<EOF
$changed
EOF

# emit_lane <name> <true|false> - report one decision, with the reason in the log.
emit_lane() {
  printf '%s=%s\n' "$1" "$2"
  if [ "$2" = true ]; then
    note "$1: needed"
  else
    note "$1: skipped, nothing it reads changed"
  fi
}

emit_lane lint "$lint"
emit_lane coverage "$coverage"
emit_lane portable "$portable"
emit_lane herdr "$herdr"
emit_lane docker "$docker"
emit_lane web "$web"
