#!/usr/bin/env bash
# cs-migrate-config.sh - move this home's user-owned files into the config/
# userspace layout (issue #38): flat portable files plus config/host/ for
# machine-specific ones, truthful extensions (.md prose, .conf settings).
#
# The mapping is owned by cs_layout_pairs in bin/cs-root-lib.sh; the fail-closed
# gate in cs_resolve_root refuses every other script while any old-name path
# exists, so a partially migrated home is loud everywhere until a re-run of this
# script converges it.
#
# Per pair the procedure is idempotent and rename(2)-atomic:
#   - old absent                     -> nothing to do
#   - new absent                     -> mv old new  (a symlink moves intact)
#   - both exist, symlinks with the  -> rm old      (a dotfiles manager such as
#     same target                                    nix ln -sfn re-created the
#                                                    old name; the new one wins)
#   - both exist, identical bytes    -> rm old
#   - both exist, anything else      -> REFUSE and name both paths; the boss
#                                       reconciles by hand, this script never
#                                       guesses which content wins
#
# Safe on a live fleet: state/, data/<id>/, and projects/ are untouched, and
# soldier briefs bake only paths under those trees. No lock is required; the
# script is re-runnable and concurrent runs converge on the same result.
#
# Usage:
#   cs-migrate-config.sh            migrate this CS_HOME (quiet when a no-op)
#   cs-migrate-config.sh --help     print this usage
#
# Exit status:
#   0  migrated or already migrated
#   1  a pair has divergent content at both the old and new path
set -eu

# This script is one of the two legitimate gate bypasses: it must resolve the
# home it is about to migrate.
CS_LAYOUT_GATE_SKIP=1
export CS_LAYOUT_GATE_SKIP

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root

case "${1:-}" in
  '') ;;
  -h|--help)
    awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
    exit 0
    ;;
  *) echo "error: unknown argument $1" >&2; exit 2 ;;
esac

RC=0
while IFS=$'\t' read -r old new; do
  if [ ! -e "$old" ] && [ ! -L "$old" ]; then
    continue
  fi
  if [ ! -e "$new" ] && [ ! -L "$new" ]; then
    mkdir -p "$(dirname "$new")"
    mv "$old" "$new"
    printf 'cs-migrate-config: moved %s -> %s\n' "$old" "$new"
    continue
  fi
  # Both exist: converge only when the two are provably the same thing.
  if [ -L "$old" ] && [ -L "$new" ] \
    && [ "$(readlink "$old")" = "$(readlink "$new")" ]; then
    rm "$old"
    printf 'cs-migrate-config: removed %s (same symlink target as %s)\n' "$old" "$new"
    continue
  fi
  if [ -f "$old" ] && [ ! -L "$old" ] && [ -f "$new" ] && [ ! -L "$new" ] \
    && cmp -s "$old" "$new"; then
    rm "$old"
    printf 'cs-migrate-config: removed %s (identical to %s)\n' "$old" "$new"
    continue
  fi
  printf 'cs-migrate-config: REFUSED: %s and %s both exist with different content; reconcile by hand and re-run\n' "$old" "$new" >&2
  RC=1
done < <(cs_layout_pairs)

mkdir -p "$CONFIG/host"
exit "$RC"
