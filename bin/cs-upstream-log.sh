#!/usr/bin/env bash
# Print firstmate commits not yet reviewed for editorial porting.
#
# Consigliere is a personal rewrite of Firstmate; upstream improvements are
# ported editorially (fresh implementations against consigliere's structure),
# never merged or cherry-picked. This read-only helper feeds the
# /upstream-review skill:
#   - resolves the firstmate checkout from config/host/upstream.conf (a local path;
#     default ../firstmate relative to the consigliere repo root),
#   - fetches its origin,
#   - reads the last-reviewed SHA from the first line of the tracked ledger
#     docs/upstream-review.md ("last-reviewed: <sha>"),
#   - prints `git log --reverse --stat <last-sha>..origin/HEAD`.
#
# The ledger is shared tracked material: the skill advances it through the
# ordinary branch-and-PR path, and this script never writes anything.
# Usage: cs-upstream-log.sh [--oneline]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root

FORMAT=stat
case "${1:-}" in
  --oneline) FORMAT=oneline ;;
  '') ;;
  -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "error: unknown argument $1" >&2; exit 2 ;;
esac

UPSTREAM=$(cat "$CONFIG/host/upstream.conf" 2>/dev/null || true)
[ -n "$UPSTREAM" ] || UPSTREAM="$CS_ROOT/../firstmate"
[ -d "$UPSTREAM/.git" ] || { echo "error: no firstmate checkout at '$UPSTREAM' (set config/host/upstream.conf)" >&2; exit 1; }

REVIEW="$CS_ROOT/docs/upstream-review.md"
LAST=""
if [ -f "$REVIEW" ]; then
  LAST=$(sed -n '1s/^last-reviewed:[[:space:]]*//p' "$REVIEW")
fi
if [ -z "$LAST" ]; then
  echo "warning: no last-reviewed SHA in $REVIEW; seed it with the firstmate SHA consigliere was ported at (first line: 'last-reviewed: <sha>')" >&2
  exit 1
fi
git -C "$UPSTREAM" cat-file -e "$LAST^{commit}" 2>/dev/null || {
  echo "error: last-reviewed SHA '$LAST' is not a commit in $UPSTREAM" >&2
  exit 1
}

git -C "$UPSTREAM" fetch --quiet origin 2>/dev/null || echo "warning: fetch failed; reviewing against the local origin refs" >&2

HEAD_REF=origin/HEAD
git -C "$UPSTREAM" rev-parse --verify --quiet "$HEAD_REF" >/dev/null || HEAD_REF=origin/main
git -C "$UPSTREAM" rev-parse --verify --quiet "$HEAD_REF" >/dev/null || HEAD_REF=HEAD

COUNT=$(git -C "$UPSTREAM" rev-list --count "$LAST..$HEAD_REF")
printf 'upstream: %s commits since last-reviewed %s (%s)\n\n' "$COUNT" "$LAST" "$HEAD_REF"
[ "$COUNT" -gt 0 ] || exit 0

if [ "$FORMAT" = oneline ]; then
  git -C "$UPSTREAM" log --reverse --oneline "$LAST..$HEAD_REF"
else
  git -C "$UPSTREAM" log --reverse --stat "$LAST..$HEAD_REF"
fi
