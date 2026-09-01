#!/usr/bin/env bash
# tests/cs-wake-queue.test.sh - wake-queue losslessness (the queue safety matrix):
# concurrent append/drain, atomic double-drain, duplicate collapse, interruption
# safety, and the drain's watcher-liveness assertion. Nothing is lost and
# nothing is double-consumed. Watcher-produced wakes are exercised in the
# watcher's own suite once one exists; these cases use the production wake
# library directly so they run with no watcher and no external tools.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRAIN="$ROOT/bin/cs-wake-drain.sh"

TMP_ROOT=$(cs_test_tmproot cs-wake-tests)

# cs-wake-drain.sh calls cs-guard.sh to assert watcher liveness on every drain.
# cs-guard.sh's first check warns when the consigliere PRIMARY checkout (CS_ROOT)
# sits on a feature branch; with no override CS_ROOT resolves to the test
# runner's own checkout, which during validation may be on a feature branch, so
# each drain would emit a spurious worktree-tangle banner. Point the tangle check
# at a fresh non-git dir to keep it inert across this suite.
CS_ROOT_OVERRIDE="$TMP_ROOT/tangle-root"
mkdir -p "$CS_ROOT_OVERRIDE"
export CS_ROOT_OVERRIDE

# append_wake <state> <kind> <key> <payload>: append a wake record to the durable
# queue in a subshell scoped to <state>, using the production wake library.
append_wake() {
  local state=$1 kind=$2 key=$3 payload=$4 lib="$ROOT/bin/cs-wake-lib.sh"
  CS_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    cs_wake_append "$2" "$3" "$4"
  ' _ "$lib" "$kind" "$key" "$payload"
}

make_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  printf '%s\n' "$dir"
}

test_concurrent_append_and_drain() {
  local dir state out1 out2 all pids i pid count unique malformed
  dir=$(make_case concurrent)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  all="$dir/all.out"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    append_wake "$state" signal "status-$i" "signal: $state/status-$i.status" &
    pids="$pids $!"
    i=$((i + 1))
  done
  CS_STATE_OVERRIDE="$state" "$DRAIN" > "$out1" &
  pids="$pids $!"
  for pid in $pids; do
    wait "$pid" || fail "concurrent append/drain subprocess failed"
  done
  CS_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" || fail "final drain failed"
  cat "$out1" "$out2" > "$all"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$all")
  [ "$count" -eq 40 ] || fail "expected 40 drained records, got $count"
  malformed=$(awk -F '\t' 'NF != 5 { bad++ } END { print bad + 0 }' "$all")
  [ "$malformed" -eq 0 ] || fail "drained records had malformed fields"
  unique=$(awk -F '\t' '{ keys[$4] = 1 } END { for (k in keys) count++; print count + 0 }' "$all")
  [ "$unique" -eq 40 ] || fail "expected 40 unique keys, got $unique"
  pass "concurrent append plus drain preserves queue records"
}

test_atomic_double_drain() {
  local dir state out1 out2 all count leftover pid1 pid2
  dir=$(make_case double-drain)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  all="$dir/all.out"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "heartbeat append failed"
  append_wake "$state" signal task "signal: $state/task.status" || fail "signal append failed"
  append_wake "$state" stale 's:cs-task' 'stale: s:cs-task' || fail "stale append failed"
  CS_STATE_OVERRIDE="$state" "$DRAIN" > "$out1" &
  pid1=$!
  CS_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" &
  pid2=$!
  wait "$pid1" || fail "first drain failed"
  wait "$pid2" || fail "second drain failed"
  cat "$out1" "$out2" > "$all"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$all")
  [ "$count" -eq 3 ] || fail "two drains consumed records more than once or lost records; got $count"
  leftover=$(CS_STATE_OVERRIDE="$state" "$DRAIN" | awk 'NF { count++ } END { print count + 0 }')
  [ "$leftover" -eq 0 ] || fail "queue was not empty after double drain"
  pass "two atomic drains cannot consume the same records twice"
}

test_drain_dedupes_obvious_duplicates() {
  local dir state out count
  dir=$(make_case dedupe)
  state="$dir/state"
  out="$dir/drain.out"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "first heartbeat append failed"
  append_wake "$state" signal task.status "signal: $state/task.status" || fail "first signal append failed"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "second heartbeat append failed"
  append_wake "$state" signal task.status "signal: $state/task.status $state/task.turn-ended" || fail "second signal append failed"
  CS_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "dedupe drain failed"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$out")
  [ "$count" -eq 2 ] || fail "expected 2 deduped records, got $count"
  grep "$(printf '\theartbeat\theartbeat\theartbeat')" "$out" >/dev/null || fail "heartbeat was not preserved"
  grep "$(printf '\tsignal\ttask.status\t')" "$out" | grep -F "$state/task.turn-ended" >/dev/null || fail "latest signal payload was not preserved"
  pass "drain collapses obvious duplicate heartbeat and signal records"
}

# The drain runs at the top of every wake-handling turn, so it also asserts
# watcher liveness via cs-guard.sh: a lapsed re-arm chain then surfaces even on a
# plain drain-and-handle turn that runs no other supervision script. It must warn
# when work is in flight with no live watcher, and stay silent right after a
# normal fire (a fresh beacon within grace), so it never false-alarms every wake.
test_drain_asserts_watcher_liveness() {
  local dir state err
  dir=$(make_case drain-liveness)
  state="$dir/state"
  err="$dir/drain.err"
  cs_write_meta "$state/x.meta" "window=test:cs-x" "kind=ship"
  CS_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || fail "drain failed while asserting liveness"
  grep -F 'WATCHER DOWN' "$err" >/dev/null || fail "drain did not surface the watcher-down banner with work in flight and no live watcher"
  : > "$err"
  touch "$state/.last-watcher-beat"
  CS_STATE_OVERRIDE="$state" CS_GUARD_GRACE=300 "$DRAIN" >/dev/null 2> "$err" || fail "drain failed with a fresh beacon"
  if grep -F 'WATCHER DOWN' "$err" >/dev/null; then
    fail "drain false-alarmed right after a normal fire (fresh beacon within grace)"
  fi
  pass "drain asserts watcher liveness: warns on a lapse, stays silent right after a fire"
}

wait_for_file_text() {  # <file> <fixed-text>
  local file=$1 expected=$2 i=0
  while [ "$i" -lt 100 ]; do
    grep -F "$expected" "$file" >/dev/null 2>&1 && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

test_interruption_before_and_after_raw_commit() {
  local dir state before_out after_out replay_out empty_out pid rc count i
  dir=$(make_case interruption)
  state="$dir/state"
  before_out="$dir/before.out"
  after_out="$dir/after.out"
  replay_out="$dir/replay.out"
  empty_out="$dir/empty.out"
  printf 'done: interruption fixture\n' > "$state/task.status"
  append_wake "$state" signal task.status "signal: task" || fail "pre-commit interruption wake append failed"

  CS_STATE_OVERRIDE="$state" CS_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT=5 "$DRAIN" > "$before_out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && ! compgen -G "$state/.wake-queue.drain.*" >/dev/null; do
    sleep 0.05
    i=$((i + 1))
  done
  compgen -G "$state/.wake-queue.drain.*" >/dev/null || { kill "$pid" 2>/dev/null || true; fail "pre-commit drain never rotated the queue"; }
  kill -TERM "$pid" 2>/dev/null || fail "could not interrupt drain before raw commitment"
  set +e
  wait "$pid"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "pre-commit interruption unexpectedly succeeded"
  # The restore put the row back in the queue, so the batch it came from is now
  # a duplicate copy. It must be gone: left behind, the next drain would adopt it
  # as an orphan and replay a record that was never lost.
  compgen -G "$state/.wake-queue.drain.*" >/dev/null \
    && fail "restoring the queue left its batch behind for the next drain to re-adopt"
  CS_STATE_OVERRIDE="$state" "$DRAIN" > "$replay_out" || fail "restored pre-commit wake did not drain"
  count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$replay_out")
  [ "$count" -eq 1 ] || fail "pre-commit interruption lost or duplicated the restored row"

  append_wake "$state" signal task.status "signal: task after commit" || fail "post-commit interruption wake append failed"
  CS_STATE_OVERRIDE="$state" CS_WAKE_ENRICH_TEST_DELAY=5 "$DRAIN" > "$after_out" &
  pid=$!
  wait_for_file_text "$after_out" "$(printf '\tsignal\ttask.status\t')" \
    || { kill "$pid" 2>/dev/null || true; fail "post-commit drain did not print its raw row"; }
  kill -TERM "$pid" 2>/dev/null || fail "could not interrupt drain after raw commitment"
  set +e
  wait "$pid"
  set -e
  CS_STATE_OVERRIDE="$state" "$DRAIN" > "$empty_out" || fail "drain after post-commit interruption failed"
  count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$after_out" "$empty_out")
  [ "$count" -eq 1 ] || fail "post-commit interruption restored or duplicated the consumed row"
  pass "interruptions restore before commitment and never replay after raw commitment"
}

# write_batch <path> <seq> <kind> <key> <payload>: append one canonical wake
# record to a batch file, standing in for what a drain rotated out of the queue.
write_batch() {
  local path=$1 seq=$2 kind=$3 key=$4 payload=$5
  printf '%s\t%s\t%s\t%s\t%s\n' "$((1700000000 + seq))" "$seq" "$kind" "$key" "$payload" >> "$path"
}

# The turn can die between the queue rotation and handling: the drain moved the
# queue into its batch file and was then killed hard enough that its trap never
# ran (SIGKILL, harness teardown, host loss). The queue is empty, the records
# sit in a batch nothing else reads, and before orphan adoption they were gone
# for good. The next drain must resurface them exactly once and never again.
test_orphaned_batch_is_replayed_exactly_once() {
  local dir state orphan first second count
  dir=$(make_case orphan-replay)
  state="$dir/state"
  orphan="$state/.wake-queue.drain.99999"
  first="$dir/first.out"
  second="$dir/second.out"
  write_batch "$orphan" 1 signal task.status 'signal: task'
  write_batch "$orphan" 2 stale 's:cs-task' 'stale: s:cs-task'

  CS_STATE_OVERRIDE="$state" "$DRAIN" > "$first" || fail "drain with an orphaned batch failed"
  count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$first")
  [ "$count" -eq 2 ] || fail "expected the orphaned batch's 2 records replayed, got $count"
  grep -F 'wake replay:' "$first" >/dev/null || fail "replayed records were not labeled as a replay"
  [ ! -e "$orphan" ] || fail "the adopted batch was not retired by the drain that printed it"
  compgen -G "$state/.wake-queue.drain.*" >/dev/null \
    && fail "the drain left a batch behind for the next drain to re-adopt"

  CS_STATE_OVERRIDE="$state" "$DRAIN" > "$second" || fail "second drain failed"
  count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$second")
  [ "$count" -eq 0 ] || fail "second drain replayed the adopted batch again; got $count"
  if grep -F 'wake replay:' "$second" >/dev/null; then
    fail "second drain claimed a replay with nothing left to replay"
  fi
  pass "an orphaned batch from a turn that died mid-drain is replayed exactly once"
}

# Adoption folds into the ordinary drain rather than running beside it: the
# orphan's records and the queue's records come out of one deduped view, so a
# key carried by both collapses to the newest payload instead of surfacing twice.
test_orphaned_batch_folds_into_the_fresh_queue() {
  local dir state orphan out count
  dir=$(make_case orphan-fold)
  state="$dir/state"
  orphan="$state/.wake-queue.drain.99998"
  out="$dir/drain.out"
  write_batch "$orphan" 1 signal task.status 'signal: stale payload'
  write_batch "$orphan" 2 stale 's:cs-other' 'stale: s:cs-other'
  append_wake "$state" signal task.status 'signal: fresh payload' || fail "fresh append failed"

  CS_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain folding an orphan into the queue failed"
  count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$out")
  [ "$count" -eq 2 ] || fail "expected 2 deduped records across the orphan and the queue, got $count"
  grep -F 'signal: fresh payload' "$out" >/dev/null || fail "the newest payload for the shared key was lost"
  if grep -F 'signal: stale payload' "$out" >/dev/null; then
    fail "the superseded payload surfaced alongside the newest one"
  fi
  grep -F 'stale: s:cs-other' "$out" >/dev/null || fail "the orphan-only record was lost"
  pass "an adopted batch is deduped against the fresh queue, not printed beside it"
}

# The successor-drain loop the adoption must not create: a drain that dies again
# while adopting keeps the records reachable, and the first drain that commits
# retires every batch at once instead of handing one forward forever.
test_repeated_adoption_converges() {
  local dir state out count leftover
  dir=$(make_case orphan-converge)
  state="$dir/state"
  out="$dir/drain.out"
  write_batch "$state/.wake-queue.drain.11111" 1 signal a.status 'signal: a'
  write_batch "$state/.wake-queue.drain.22222" 2 signal b.status 'signal: b'
  write_batch "$state/.wake-queue.drain.33333" 3 signal a.status 'signal: a again'

  CS_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain adopting several orphans failed"
  count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$out")
  [ "$count" -eq 2 ] || fail "expected 2 deduped records across 3 orphaned batches, got $count"
  compgen -G "$state/.wake-queue.drain.*" >/dev/null \
    && fail "a committed drain left an orphaned batch behind"
  leftover=$(CS_STATE_OVERRIDE="$state" "$DRAIN" | awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }')
  [ "$leftover" -eq 0 ] || fail "adoption fed itself: the next drain replayed the retired batches"
  pass "adopting several orphaned batches converges in one committed drain"
}

test_concurrent_append_and_drain
test_atomic_double_drain
test_drain_dedupes_obvious_duplicates
test_drain_asserts_watcher_liveness
test_interruption_before_and_after_raw_commit
test_orphaned_batch_is_replayed_exactly_once
test_orphaned_batch_folds_into_the_fresh_queue
test_repeated_adoption_converges
