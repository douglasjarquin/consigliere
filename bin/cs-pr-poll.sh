#!/usr/bin/env bash
# Static watcher program for a validated PR poll sidecar. Direct sidecar reads
# consume and validate its exact-head and capacity-attestation fields but never
# interpret them; bin/cs-board-capacity.sh is their only scheduling consumer.
# It emits exactly one merged line for a merged GitHub PR and stays silent
# otherwise, including on every error, so a failed lookup can never be read as
# a merge. The identity is data in the sidecar and is never interpolated into
# this source: these bytes are identical for every task.
# Consigliere watches GitHub only. bin/cs-pr-lib.sh can validate a
# gitlab-tagged sidecar, but consigliere never arms one (bin/cs-pr-check.sh
# refuses GitLab URLs loudly), so any non-github provider reaching this poll
# exits silently under the same silence-on-error contract instead of being
# misread as a GitHub identity.
set -u
LC_ALL=C
export LC_ALL

if [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  IFS= read -r head <&3 || exit 0
  IFS= read -r capacity <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
  [[ -z "$head" || "$head" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]] || exit 0
  case "$capacity" in
    hold) ;;
    release-reviewed-green) [ -n "$head" ] || exit 0 ;;
    *) exit 0 ;;
  esac
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0
    state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || exit 0
    [ "$state" = MERGED ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
