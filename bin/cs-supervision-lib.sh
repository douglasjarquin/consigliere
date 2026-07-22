# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/cs-supervision-lib.sh
#
# True exactly when a consigliere home has in-flight work (a state/<id>.meta
# exists) but no watcher has a fresh liveness beacon (state/.last-watcher-beat,
# touched every poll cycle, within the grace window). bin/cs-guard.sh uses this
# grace-based warning predicate directly; bin/cs-turnend-guard.sh uses the
# status fields here for its banner.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
cs_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# cs_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   CS_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   CS_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   CS_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   CS_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $CS_GUARD_GRACE, then 300, matching cs-guard.sh.
# Always returns 0; callers read the vars, or use cs_supervision_unhealthy.
cs_supervision_status() {
  local state=$1 grace=${2:-${CS_GUARD_GRACE:-300}} meta beat m age
  CS_SUP_IN_FLIGHT=0
  CS_SUP_WATCHER_FRESH=false
  CS_SUP_BEACON_DESC=never
  CS_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    CS_SUP_IN_FLIGHT=$((CS_SUP_IN_FLIGHT + 1))
  done

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(cs_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      CS_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && CS_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers after sourcing.
      CS_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers after sourcing.
  [ -s "$state/.wake-queue" ] && CS_SUP_QUEUE_PENDING=true
  return 0
}

# cs_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly in the dangerous state: in-flight work exists and no
# watcher has a fresh beacon. Exit 1 (false) otherwise, including zero in-flight.
cs_supervision_unhealthy() {
  cs_supervision_status "$@"
  [ "$CS_SUP_IN_FLIGHT" -gt 0 ] && [ "$CS_SUP_WATCHER_FRESH" = false ]
}
