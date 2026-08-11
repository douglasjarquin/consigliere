#!/usr/bin/env bash
# Shared durable wake queue and portable lock helpers.
#
# cs_pid_identity, the reuse-proof process identity this file's watcher-lock
# validation compares, is owned by bin/cs-session-pid-lib.sh alongside the pid
# ancestry walk and is re-exported here by sourcing it.

CS_WAKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-session-pid-lib.sh
. "$CS_WAKE_LIB_DIR/cs-session-pid-lib.sh"
CS_WAKE_DEFAULT_ROOT="$(cd "$CS_WAKE_LIB_DIR/.." && pwd)"
CS_ROOT="${CS_ROOT_OVERRIDE:-${CS_ROOT:-$CS_WAKE_DEFAULT_ROOT}}"
CS_HOME="${CS_HOME:-${CS_ROOT_OVERRIDE:-$CS_ROOT}}"
STATE="${CS_STATE_OVERRIDE:-${STATE:-$CS_HOME/state}}"
CS_WAKE_QUEUE="${CS_WAKE_QUEUE:-$STATE/.wake-queue}"
CS_WAKE_QUEUE_LOCK="${CS_WAKE_QUEUE_LOCK:-$STATE/.wake-queue.lock}"
# One owner for the drain's temporary file names. bin/cs-wake-drain.sh rotates
# the queue into a batch under CS_WAKE_BATCH_PREFIX and adopts any batch it still
# finds there, so the name it writes and the name its orphan scan looks for can
# never drift apart.
CS_WAKE_BATCH_PREFIX="${CS_WAKE_BATCH_PREFIX:-$STATE/.wake-queue.drain.}"
CS_WAKE_RESTORE_PREFIX="${CS_WAKE_RESTORE_PREFIX:-$STATE/.wake-queue.restore.}"
CS_LOCK_STALE_AFTER="${CS_LOCK_STALE_AFTER:-2}"
mkdir -p "$STATE"

cs_current_pid() {
  printf '%s\n' "${BASHPID:-$$}"
}

cs_pid_alive() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

cs_path_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

cs_path_age() {
  local path=$1 m
  m=$(cs_path_mtime "$path") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

cs_watcher_lock_matches_pid() {
  local state=$1 watch_path=$2 pid=$3 home=${4:-$CS_HOME} lockdir lock_home lock_path lock_identity current_identity
  lockdir="$state/.watch.lock"
  lock_home=$(cat "$lockdir/cs-home" 2>/dev/null || true)
  lock_path=$(cat "$lockdir/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$lockdir/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$home" ] || return 1
  [ "$lock_path" = "$watch_path" ] || return 1
  [ -n "$lock_identity" ] || return 1
  current_identity=$(cs_pid_identity "$pid") || return 1
  [ "$current_identity" = "$lock_identity" ]
}

CS_WATCHER_HEALTHY_PID=
cs_watcher_healthy() {
  local state=$1 watch_path=$2 grace=${3:-${CS_GUARD_GRACE:-300}} home=${4:-$CS_HOME} lockdir beat pid age
  CS_WATCHER_HEALTHY_PID=
  lockdir="$state/.watch.lock"
  beat="$state/.last-watcher-beat"
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  cs_pid_alive "$pid" || return 1
  cs_watcher_lock_matches_pid "$state" "$watch_path" "$pid" "$home" || return 1
  age=$(cs_path_age "$beat")
  [ "$age" -lt "$grace" ] || return 1
  # shellcheck disable=SC2034 # Read by callers after cs_watcher_healthy returns.
  CS_WATCHER_HEALTHY_PID=$pid
  return 0
}

cs_lock_clean_known_files() {
  local lockdir=$1
  rm -f \
    "$lockdir/pid" \
    "$lockdir/cs-home" \
    "$lockdir/pid-identity" \
    "$lockdir/watcher-path" \
    2>/dev/null || true
}

cs_lock_abs_path() {
  local path=$1 dir base
  dir=$(dirname "$path")
  base=$(basename "$path")
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "$base"
}

cs_lock_owner_dir() {
  local lockdir=$1 lock_abs
  lock_abs=$(cs_lock_abs_path "$lockdir") || return 1
  mktemp -d "${lock_abs}.owner.XXXXXX" 2>/dev/null
}

cs_lock_prepare_owner() {
  local ownerdir=$1 mypid back
  mypid=${BASHPID:-$$}
  printf '%s\n' "$mypid" > "$ownerdir/pid" 2>/dev/null || return 1
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  [ "$back" = "$mypid" ]
}

cs_lock_link_owner() {
  local lockdir=$1 owner
  owner=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ -n "$owner" ] || return 1
  case "$owner" in
    /*) printf '%s\n' "$owner" ;;
    *) printf '%s/%s\n' "$(dirname "$lockdir")" "$owner" ;;
  esac
}

cs_lock_points_to_owner() {
  local lockdir=$1 ownerdir=$2 actual
  actual=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ "$actual" = "$ownerdir" ]
}

cs_lock_discard_owner() {
  local ownerdir=$1
  [ -n "$ownerdir" ] || return 0
  cs_lock_clean_known_files "$ownerdir"
  rmdir "$ownerdir" 2>/dev/null || true
}

cs_lock_remove_stray_owner_link() {
  local lockdir=$1 ownerdir=$2 stray
  stray="$lockdir/$(basename "$ownerdir")"
  if [ -L "$stray" ] && [ "$(readlink "$stray" 2>/dev/null || true)" = "$ownerdir" ]; then
    rm -f "$stray" 2>/dev/null || true
  fi
}

cs_lock_claim_blocked_by_steal() {
  local lockdir=$1 allowed_steal_owner=${2:-} steal
  steal="$lockdir.steal"
  [ -e "$steal" ] || [ -L "$steal" ] || return 1
  if [ -n "$allowed_steal_owner" ] && cs_lock_points_to_owner "$steal" "$allowed_steal_owner"; then
    return 1
  fi
  return 0
}

cs_lock_claim() {
  local lockdir=$1 ownerdir=$2 allowed_steal_owner=${3:-} mypid back
  mypid=${BASHPID:-$$}
  if ! { printf '%s\n' "$mypid" > "$ownerdir/pid"; } 2>/dev/null; then
    cs_lock_discard_owner "$ownerdir"
    return 1
  fi
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  if [ "$back" != "$mypid" ]; then
    cs_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! cs_lock_points_to_owner "$lockdir" "$ownerdir"; then
    cs_lock_discard_owner "$ownerdir"
    return 1
  fi
  if cs_lock_claim_blocked_by_steal "$lockdir" "$allowed_steal_owner"; then
    if cs_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
    cs_lock_discard_owner "$ownerdir"
    return 1
  fi
  return 0
}

cs_lock_try_create() {
  local lockdir=$1 allowed_steal_owner=${2:-} ownerdir
  CS_LOCK_OWNER_DIR=
  ownerdir=$(cs_lock_owner_dir "$lockdir") || return 1
  if [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    cs_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! cs_lock_prepare_owner "$ownerdir"; then
    cs_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ln -s "$ownerdir" "$lockdir" 2>/dev/null && cs_lock_points_to_owner "$lockdir" "$ownerdir"; then
    if cs_lock_claim "$lockdir" "$ownerdir" "$allowed_steal_owner"; then
      CS_LOCK_OWNER_DIR=$ownerdir
      return 0
    fi
    if cs_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
  else
    cs_lock_remove_stray_owner_link "$lockdir" "$ownerdir"
  fi
  cs_lock_discard_owner "$ownerdir"
  return 1
}

cs_lock_remove_path() {
  local lockdir=$1 ownerdir
  if [ -L "$lockdir" ]; then
    ownerdir=$(cs_lock_link_owner "$lockdir" 2>/dev/null || true)
    rm -f "$lockdir" 2>/dev/null || return 1
    [ -n "$ownerdir" ] && cs_lock_discard_owner "$ownerdir"
    return 0
  fi
  cs_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null
}

cs_lock_mid_acquire_is_fresh() {
  local lockdir=$1 pid=$2 mid_acquire_stale
  case "$pid" in
    ''|*[!0-9]*)
      mid_acquire_stale=$CS_LOCK_STALE_AFTER
      [ "$mid_acquire_stale" -lt 2 ] && mid_acquire_stale=2
      [ "$(cs_path_age "$lockdir")" -lt "$mid_acquire_stale" ]
      return
      ;;
  esac
  return 1
}

cs_lock_recheck_stale_owner() {
  local lockdir=$1 expected_owner=$2 expected_pid=$3 actual_pid
  if [ -n "$expected_owner" ]; then
    cs_lock_points_to_owner "$lockdir" "$expected_owner" || return 1
  elif [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    [ -d "$lockdir" ] && [ ! -L "$lockdir" ] || return 1
  fi
  actual_pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$actual_pid" = "$expected_pid" ] || return 1
  if cs_pid_alive "$actual_pid"; then
    return 1
  fi
  if cs_lock_mid_acquire_is_fresh "$lockdir" "$actual_pid"; then
    return 1
  fi
  return 0
}

cs_lock_try_acquire() {
  local lockdir=$1 pid steal cur rc steal_owner primary_owner
  CS_LOCK_HELD_PID=
  CS_LOCK_OWNER_DIR=

  if cs_lock_try_create "$lockdir"; then
    return 0
  fi

  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  if cs_pid_alive "$pid"; then
    CS_LOCK_HELD_PID=$pid
    return 1
  fi
  if cs_lock_mid_acquire_is_fresh "$lockdir" "$pid"; then
    CS_LOCK_HELD_PID=$pid
    return 1
  fi

  steal="$lockdir.steal"
  if ! cs_lock_try_acquire "$steal"; then
    CS_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    CS_LOCK_OWNER_DIR=
    return 1
  fi
  steal_owner=${CS_LOCK_OWNER_DIR:-}

  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if cs_pid_alive "$cur"; then
    cs_lock_release "$steal"
    CS_LOCK_HELD_PID=$cur
    CS_LOCK_OWNER_DIR=
    return 1
  fi
  if cs_lock_mid_acquire_is_fresh "$lockdir" "$cur"; then
    cs_lock_release "$steal"
    CS_LOCK_HELD_PID=$cur
    CS_LOCK_OWNER_DIR=
    return 1
  fi
  if ! cs_lock_points_to_owner "$steal" "$steal_owner"; then
    cs_lock_release "$steal"
    CS_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    CS_LOCK_OWNER_DIR=
    return 1
  fi

  primary_owner=
  if [ -L "$lockdir" ]; then
    primary_owner=$(cs_lock_link_owner "$lockdir" 2>/dev/null || true)
  fi
  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if ! cs_lock_recheck_stale_owner "$lockdir" "$primary_owner" "$cur"; then
    cs_lock_release "$steal"
    CS_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    CS_LOCK_OWNER_DIR=
    return 1
  fi

  cs_lock_remove_path "$lockdir" || true
  rc=1
  if cs_lock_try_create "$lockdir" "$steal_owner"; then
    rc=0
  fi
  if [ "$rc" -ne 0 ]; then
    # shellcheck disable=SC2034 # Read by callers after cs_lock_try_acquire returns.
    CS_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    CS_LOCK_OWNER_DIR=
  fi
  cs_lock_release "$steal"
  return "$rc"
}

cs_lock_acquire_wait() {
  local lockdir=$1
  while ! cs_lock_try_acquire "$lockdir"; do
    sleep 0.1
  done
}

cs_lock_release() {
  local lockdir=$1 pid current ownerdir
  current=${BASHPID:-$$}
  if [ -L "$lockdir" ]; then
    ownerdir=$(cs_lock_link_owner "$lockdir" 2>/dev/null || true)
    [ -n "$ownerdir" ] || return 0
    pid=$(cat "$ownerdir/pid" 2>/dev/null || true)
    [ "$pid" = "$current" ] || return 0
    cs_lock_points_to_owner "$lockdir" "$ownerdir" || return 0
    rm -f "$lockdir" 2>/dev/null || return 0
    cs_lock_discard_owner "$ownerdir"
    return 0
  fi
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$pid" = "$current" ] || return 0
  cs_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null || true
}

cs_wake_clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

cs_wake_append() {
  local kind=$1 key=$2 payload=$3 clean_key clean_payload epoch seq seq_file status
  case "$kind" in
    signal|stale|check|capo|heartbeat) ;;
    *) printf 'cs_wake_append: invalid wake kind: %s\n' "$kind" >&2; return 2 ;;
  esac

  clean_key=$(printf '%s' "$key" | cs_wake_clean_field)
  clean_payload=$(printf '%s' "$payload" | cs_wake_clean_field)
  epoch=$(date +%s)
  seq_file="$STATE/.wake-queue.seq"
  status=0

  cs_lock_acquire_wait "$CS_WAKE_QUEUE_LOCK"
  seq=$(cat "$seq_file" 2>/dev/null || echo 0)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  printf '%s\n' "$seq" > "$seq_file" || status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$seq" "$kind" "$clean_key" "$clean_payload" >> "$CS_WAKE_QUEUE" || status=$?
  fi
  cs_lock_release "$CS_WAKE_QUEUE_LOCK"
  return "$status"
}

# Create an empty rotation batch and print its path. The name is unique rather
# than pid-derived, so a fresh batch can never land on an orphaned batch that an
# interrupted drain left behind and clobber records nothing else can reach.
cs_wake_new_batch() {
  mktemp "${CS_WAKE_BATCH_PREFIX}XXXXXX" 2>/dev/null
}

cs_wake_restore_queue() {
  local drained=$1 restore
  restore="${CS_WAKE_RESTORE_PREFIX}$(cs_current_pid)"
  if [ -e "$CS_WAKE_QUEUE" ]; then
    if cat "$drained" "$CS_WAKE_QUEUE" > "$restore" && mv "$restore" "$CS_WAKE_QUEUE"; then
      # The records are back in the queue, so the batch is now a duplicate copy.
      # Leaving it on disk would make the next drain adopt it as an orphan and
      # replay records that were never lost in the first place.
      rm -f "$drained"
      return 0
    fi
    rm -f "$restore"
    return 1
  fi
  mv "$drained" "$CS_WAKE_QUEUE"
}

# Print one deduped view over one or more queue/batch files, oldest file first.
# Multiple files are how the drain folds an adopted orphan batch in with the
# freshly rotated queue: dedupe then runs over the union, so a key carried by
# both keeps its earliest position and its latest payload.
cs_wake_print_deduped() {
  awk -F '\t' '
    NF >= 5 {
      dedupe = $3 SUBSEP $4
      if ($3 == "heartbeat") {
        dedupe = "heartbeat"
      }
      if (!(dedupe in seen)) {
        order[++count] = dedupe
        seen[dedupe] = 1
      }
      line[dedupe] = $0
    }
    END {
      for (i = 1; i <= count; i++) {
        print line[order[i]]
      }
    }
  ' "$@"
}

# Map one structurally valid signal key to its home-local status filename.
# Queue payload text is intentionally ignored: it is display data, not a path
# authority. The caller still verifies the resulting regular file immediately
# before its bounded read.
CS_WAKE_STATUS_KEY=
CS_WAKE_STATUS_HISTORICAL=false
cs_wake_status_key_map() {  # <queue-key>
  local key=$1 id
  CS_WAKE_STATUS_KEY=
  CS_WAKE_STATUS_HISTORICAL=false
  case "$key" in
    *.status)
      id=${key%.status}
      ;;
    *.turn-ended)
      id=${key%.turn-ended}
      CS_WAKE_STATUS_HISTORICAL=true
      ;;
    *)
      return 1
      ;;
  esac
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#id}" -le 64 ] || return 1
  CS_WAKE_STATUS_KEY="$id.status"
}

cs_wake_annotation_manifest() {  # <deduped-raw-rows>
  local rows=$1 epoch seq kind key payload
  while IFS=$(printf '\t') read -r epoch seq kind key payload; do
    [ "$kind" = signal ] || continue
    cs_wake_status_key_map "$key" || continue
    if [ "$CS_WAKE_STATUS_HISTORICAL" = true ]; then
      printf '%s\thistorical\n' "$CS_WAKE_STATUS_KEY"
    else
      printf '%s\tdirect\n' "$CS_WAKE_STATUS_KEY"
    fi
  done <<EOF
$rows
EOF
}

CS_WAKE_EVENT_LINE=
CS_WAKE_EVENT_TRUNCATED=false
cs_wake_latest_event() {  # <validated-status-path> <tail-byte-cap>
  local path=$1 tail_bytes=$2 result size chunk record line_number
  CS_WAKE_EVENT_LINE=
  CS_WAKE_EVENT_TRUNCATED=false
  result=$(perl -MFcntl=:DEFAULT -e '
    my ($path, $limit) = @ARGV;
    sysopen(my $file, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
    my @stat = stat $file or exit 1;
    exit 1 unless -f _;
    my $size = $stat[7];
    exit 1 unless $size =~ /\A\d+\z/;
    my $start = $size > $limit ? $size - $limit : 0;
    seek($file, $start, 0) or exit 1;
    printf "%s\t", $size or exit 1;
    my $remaining = $size - $start;
    while ($remaining > 0) {
      my $read = read($file, my $buffer, $remaining);
      exit 1 unless defined $read;
      last unless $read;
      print $buffer or exit 1;
      $remaining -= $read;
    }
  ' "$path" "$tail_bytes" 2>/dev/null) || return 1
  size=${result%%$'\t'*}
  chunk=${result#*$'\t'}
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$chunk" ] || return 1
  record=$(printf '%s' "$chunk" | LC_ALL=C awk '
    /[^[:space:]]/ { line = $0; line_number = NR }
    END { if (line_number) printf "%d\t%s", line_number, line }
  ') || return 1
  [ -n "$record" ] || return 1
  line_number=${record%%	*}
  CS_WAKE_EVENT_LINE=${record#*	}
  CS_WAKE_EVENT_LINE=$(printf '%s' "$CS_WAKE_EVENT_LINE" | LC_ALL=C tr '\t\r' '  ')
  if [ "$size" -gt "$tail_bytes" ] && [ "$line_number" -eq 1 ]; then
    CS_WAKE_EVENT_TRUNCATED=true
  fi
}

# Print supplemental drain-time context only after the caller has committed the
# raw queue consumption and released the append lock. The limits are constants,
# so status-file volume cannot turn a drain into an unbounded context read.
cs_wake_print_annotations() {  # <deduped-raw-rows>
  local rows=$1 manifest status_key mode path prefix line suffix keep bytes
  local output='' used=0 omitted=0 read_omitted=0 annotation_marker marker_reserve=192
  local tail_bytes=8192 item_bytes=2048 global_bytes=8192 read_cap=8 reads=0
  local LC_ALL=C

  manifest=$(cs_wake_annotation_manifest "$rows" | awk -F '\t' '
    {
      key = $1
      if (!(key in seen)) {
        order[++count] = key
        seen[key] = 1
        mode[key] = $2
      } else if ($2 == "direct") {
        mode[key] = "direct"
      }
    }
    END {
      for (i = 1; i <= count; i++) print order[i] "\t" mode[order[i]]
    }
  ') || return 0

  # Test-only latency seam for proving that queue appends remain independent of
  # a slow best-effort annotation phase.
  case "${CS_WAKE_ENRICH_TEST_DELAY:-0}" in
    0) ;;
    ''|*[!0-9]*) ;;
    *) sleep "$CS_WAKE_ENRICH_TEST_DELAY" ;;
  esac

  while IFS=$(printf '\t') read -r status_key mode; do
    [ -n "$status_key" ] || continue
    if [ "$reads" -ge "$read_cap" ]; then
      read_omitted=$((read_omitted + 1))
      continue
    fi
    reads=$((reads + 1))
    path="$STATE/$status_key"
    cs_wake_latest_event "$path" "$tail_bytes" || continue
    prefix="wake annotation: latest wake-EVENT observed at drain, not current state"
    if [ "$mode" = historical ]; then
      prefix="$prefix; historical / not necessarily the triggering event"
    fi
    line="$prefix: $status_key: $CS_WAKE_EVENT_LINE"
    suffix=''
    [ "$CS_WAKE_EVENT_TRUNCATED" = false ] || suffix=' [truncated]'
    line="$line$suffix"
    if [ $(( ${#line} + 1 )) -gt "$item_bytes" ]; then
      suffix=' [truncated]'
      keep=$((item_bytes - ${#suffix} - 1))
      line="${line:0:$keep}$suffix"
    fi
    bytes=$(( ${#line} + 1 ))
    if [ $((used + bytes + marker_reserve)) -gt "$global_bytes" ]; then
      omitted=$((omitted + 1))
      continue
    fi
    output="$output$line
"
    used=$((used + bytes))
  done <<EOF
$manifest
EOF

  printf '%s' "$output"
  if [ "$omitted" -gt 0 ]; then
    annotation_marker="wake annotation: $omitted annotations omitted (global enrichment byte cap)"
    printf '%s\n' "$annotation_marker"
  fi
  if [ "$read_omitted" -gt 0 ]; then
    annotation_marker="wake annotation: $read_omitted annotations omitted (enrichment read cap)"
    printf '%s\n' "$annotation_marker"
  fi
  return 0
}
