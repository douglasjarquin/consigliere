#!/usr/bin/env bash
# Retire an intentional custom watcher check, its trust binding, and its
# watcher sidecars - the safe owner of custom-check removal, so nobody
# improvises `rm` with unset STATE/ID variables.
# Usage: cs-check-unregister.sh <id>
# Pass only the id. An unset CS_STATE_OVERRIDE selects CS_HOME/state; an
# explicitly EMPTY override, an invalid id, or a resolved state path that is
# not an existing non-symlink directory is refused before any removal.
# Each existing named artifact must be an ordinary single-link file on the
# state directory's device; only these names are removed, when present:
#   state/<id>.check.sh               the check itself
#   state/<id>.check-trust            its content binding (cs-check-register.sh)
#   state/<id>.pr-poll                the merge poll's data sidecar (cs-pr-check.sh)
#   state/<id>.pr-poll-registration   the merge poll's registration record
#   state/<id>.board-seen             the board sweep's seen record (cs-board-watch.sh)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A set-but-empty override is a caller bug (an agent interpolating an unset
# variable), never a request for the default state directory; refuse it before
# cs_resolve_root's ${CS_STATE_OVERRIDE:-...} would silently default it.
if [ -n "${CS_STATE_OVERRIDE+x}" ] && [ -z "${CS_STATE_OVERRIDE}" ]; then
  echo "error: CS_STATE_OVERRIDE is set but empty; refusing to guess a state directory" >&2
  exit 1
fi

# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root

# shellcheck source=bin/cs-pr-lib.sh
. "$SCRIPT_DIR/cs-pr-lib.sh"

if [ "$#" -ne 1 ] || ! cs_pr_task_id_valid "$1"; then
  echo "error: invalid custom check unregistration" >&2
  exit 2
fi

ID=$1
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: state directory is unavailable" >&2; exit 1; }
STATE_DEVICE=$(cs_pr_file_device "$STATE") || { echo "error: state directory is unavailable" >&2; exit 1; }

ARTIFACTS=(
  "$STATE/$ID.check.sh"
  "$STATE/$ID.check-trust"
  "$STATE/$ID.pr-poll"
  "$STATE/$ID.pr-poll-registration"
  "$STATE/$ID.board-seen"
)

for artifact in "${ARTIFACTS[@]}"; do
  [ -e "$artifact" ] || [ -L "$artifact" ] || continue
  if [ ! -f "$artifact" ] || [ -L "$artifact" ] \
    || [ "$(cs_pr_file_device "$artifact")" != "$STATE_DEVICE" ] \
    || [ "$(cs_pr_file_link_count "$artifact")" != 1 ]; then
    echo "error: custom check is unsafe to remove" >&2
    exit 1
  fi
done

rm -f -- "${ARTIFACTS[@]}" || { echo "error: custom check could not be removed" >&2; exit 1; }
printf 'unregistered: state/%s.check.sh\n' "$ID"
