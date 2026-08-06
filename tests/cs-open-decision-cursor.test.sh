#!/usr/bin/env bash
# tests/cs-open-decision-cursor.test.sh - the cursor-backed incremental
# open-decisions fold (status_open_decisions_incremental and its fleet-wide
# scan_open_decisions_incremental wrapper in bin/cs-classify-lib.sh).
# The incremental fold must agree byte-for-byte with the authoritative
# whole-file fold (status_open_decisions) on every log, fold only newly
# appended bytes on a steady-state call, fall back to a full re-fold on a
# missing cursor, a truncated log, and a replaced/rotated/recreated log (even
# at the same size, via the device+inode identity check), and on a genuine
# read failure report the already-trusted persisted set unchanged without
# destroying the cursor.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLASSIFY="$ROOT/bin/cs-classify-lib.sh"

TMP_ROOT=$(cs_test_tmproot cs-open-decision-cursor)

make_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  printf '%s\n' "$dir"
}

# fold_full <status-file>: the authoritative whole-file fold.
fold_full() {
  bash -c '. "$1"; status_open_decisions "$2"' _ "$CLASSIFY" "$1"
}

# fold_inc <status-file>: the cursor-backed incremental fold. Honors an
# exported CS_OPEN_DECISIONS_READ_PROBE for the folded-bytes assertions.
fold_inc() {
  bash -c '. "$1"; status_open_decisions_incremental "$2"' _ "$CLASSIFY" "$1"
}

fold_inc_with_failed_stage() {
  bash -c '
    . "$1"
    printf() {
      case ${1-} in
        "fold-contract=%s\\n") return 1 ;;
        *) builtin printf "$@" ;;
      esac
    }
    status_open_decisions_incremental "$2"
  ' _ "$CLASSIFY" "$1"
}

fold_inc_with_predictable_symlinks() {
  bash -c '
    . "$1"
    f=$2
    cf=$(_cs_decision_cursor_path "$f")
    ln -s "$3" "$cf.read.$$" || exit 1
    ln -s "$4" "$cf.tmp.$$" || exit 1
    status_open_decisions_incremental "$f"
  ' _ "$CLASSIFY" "$1" "$2" "$3"
}

# scan_inc <state>: the fleet-wide incremental wrapper.
scan_inc() {
  bash -c '. "$1"; scan_open_decisions_incremental "$2"' _ "$CLASSIFY" "$1"
}

cursor_of() {  # <state> <task>
  printf '%s/.decision-cursor-%s' "$1" "$2"
}

test_new_task_without_cursor_matches_full_fold() {
  local dir state f out full
  dir=$(make_case no-cursor); state="$dir/state"
  f="$state/t1.status"
  printf 'working: start\nneeds-decision [key=api]: pick A or B\nworking: more\n' > "$f"
  out=$(fold_inc "$f")
  full=$(fold_full "$f")
  [ "$out" = "$full" ] || fail "first incremental call must equal the full fold (inc: '$out' full: '$full')"
  assert_present "$(cursor_of "$state" t1)" "the first call must persist a cursor"
  assert_grep "offset=" "$(cursor_of "$state" t1)" "the cursor must record a byte offset"
  assert_grep "ident=" "$(cursor_of "$state" t1)" "the cursor must record a device:inode identity"
  assert_grep "$(printf 'fold-contract=resolve:resolved\theld:captain-held')" \
    "$(cursor_of "$state" t1)" "the cursor must record its effective fold contract"
  pass "a new task with no cursor takes the full re-fold path and writes the cursor"
}

test_steady_state_folds_only_new_bytes() {
  local dir state f probe append out
  dir=$(make_case steady); state="$dir/state"
  f="$state/t1.status"
  probe="$dir/probe"
  printf 'working: start\nneeds-decision [key=api]: pick A or B\n' > "$f"
  CS_OPEN_DECISIONS_READ_PROBE="$probe" fold_inc "$f" > /dev/null
  : > "$probe"
  # No new bytes: the steady-state call must read nothing and still report the
  # persisted open set.
  out=$(CS_OPEN_DECISIONS_READ_PROBE="$probe" fold_inc "$f")
  assert_contains "$out" "$(printf 'api\tneeds-decision\tpick A or B')" \
    "a no-new-bytes call must still report the persisted open set"
  [ ! -s "$probe" ] || fail "a no-new-bytes call must fold zero bytes (probe: $(cat "$probe"))"
  # An append: exactly the appended byte count is folded, not the whole file.
  append='resolved [key=api]: picked A'
  printf '%s\n' "$append" >> "$f"
  out=$(CS_OPEN_DECISIONS_READ_PROBE="$probe" fold_inc "$f")
  [ -z "$out" ] || fail "the appended resolution must close the open decision (got: '$out')"
  assert_grep "$(printf '\t%s' "$(( ${#append} + 1 ))")" "$probe" \
    "the steady-state call must fold exactly the appended bytes"
  [ "$(wc -l < "$probe" | tr -d ' ')" = 1 ] || fail "exactly one chunk read expected: $(cat "$probe")"
  pass "a steady-state call folds only newly appended bytes"
}

test_incremental_agrees_with_full_fold_line_by_line() {
  local dir state f full inc log line
  dir=$(make_case agreement); state="$dir/state"
  f="$state/t1.status"
  # Every fold-rule branch: the three opening verbs, keyed and default keys,
  # resolve, re-open, and captain-held's needs-review exception.
  log=$(cat <<'EOF'
working: start
needs-decision [key=api]: pick A or B
needs-review: built the thing
blocked [key=infra]: waiting on quota
resolved [key=api]: picked A
captain-held: transfer attempt on the open needs-review
captain-held [key=infra]: parked with the boss
needs-decision [key=api]: reopened after new evidence
done: unrelated finish
EOF
)
  : > "$f"
  while IFS= read -r line; do
    printf '%s\n' "$line" >> "$f"
    # Fold after EVERY append so the incremental path exercises each rule
    # branch on its own small chunk rather than one big first-call re-fold.
    inc=$(fold_inc "$f")
    full=$(fold_full "$f")
    [ "$inc" = "$full" ] || fail "strategies disagree after '$line' (inc: '$inc' full: '$full')"
  done <<EOF
$log
EOF
  assert_contains "$inc" "$(printf 'default\tneeds-review\tbuilt the thing')" \
    "captain-held must never close a needs-review decision"
  assert_not_contains "$inc" "infra" "captain-held must close the blocked decision"
  assert_contains "$inc" "reopened after new evidence" "a re-opened key must be open again"
  pass "full and incremental strategies agree on every prefix of the same log"
}

test_truncated_log_refolds_from_scratch() {
  local dir state f out full
  dir=$(make_case truncated); state="$dir/state"
  f="$state/t1.status"
  printf 'needs-decision [key=a]: first\nneeds-decision [key=b]: second\n' > "$f"
  fold_inc "$f" > /dev/null
  # Truncate to a shorter, different log: the shrink invalidates the cursor.
  printf 'needs-decision [key=c]: only this\n' > "$f"
  out=$(fold_inc "$f")
  full=$(fold_full "$f")
  [ "$out" = "$full" ] || fail "a truncated log must re-fold from scratch (inc: '$out' full: '$full')"
  assert_not_contains "$out" "first" "stale pre-truncation decisions must not survive"
  assert_contains "$out" "$(printf 'c\tneeds-decision\tonly this')" "the new content must be folded"
  pass "a truncated log invalidates the cursor and re-folds from scratch"
}

test_zero_byte_invalidation_persists_reset_cursor() {
  local dir state f cursor out full old_size new_size
  dir=$(make_case zero-byte); state="$dir/state"
  f="$state/t1.status"
  cursor=$(cursor_of "$state" t1)
  printf '%s\n' \
    'needs-decision [key=old]: stale decision' \
    'working: 11111111111111111111111111111111111111111111111111111111111111111111111111111111' > "$f"
  old_size=$(wc -c < "$f" | tr -d ' ')
  fold_inc "$f" > /dev/null

  : > "$f"
  out=$(fold_inc "$f")
  [ -z "$out" ] || fail "an empty invalidated log must have no open decisions (got: '$out')"
  assert_grep 'offset=0' "$cursor" "a zero-byte invalidation must persist offset zero"
  assert_no_grep 'stale decision' "$cursor" "a zero-byte invalidation must discard the stale open set"

  printf '%s\n' \
    'needs-decision [key=new]: decision after reset' \
    'working: 222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222' > "$f"
  new_size=$(wc -c < "$f" | tr -d ' ')
  [ "$new_size" -gt "$old_size" ] || fail "fixture bug: regrown log must exceed the stale offset"
  out=$(fold_inc "$f")
  full=$(fold_full "$f")
  [ "$out" = "$full" ] || fail "regrowth after an empty invalidation must fold from byte zero (inc: '$out' full: '$full')"
  assert_contains "$out" "$(printf 'new\tneeds-decision\tdecision after reset')" \
    "regrowth must not skip the new prefix"
  pass "a zero-byte invalidation persists its reset cursor before regrowth"
}

test_fold_contract_change_invalidates_cursor() {
  local dir state f cursor out full
  dir=$(make_case fold-contract); state="$dir/state"
  f="$state/t1.status"
  cursor=$(cursor_of "$state" t1)
  printf '%s\n' \
    'needs-decision [key=choice]: pick one' \
    'closed [key=choice]: picked one' \
    'blocked [key=quota]: waiting' \
    'parked [key=quota]: transferred' > "$f"

  out=$(CS_CLASSIFY_RESOLVE_VERB=closed \
    CS_CLASSIFY_BOSS_HELD_VERB=parked fold_inc "$f")
  [ -z "$out" ] || fail "the configured close verbs must close both decisions (got: '$out')"
  assert_grep "$(printf 'fold-contract=resolve:closed\theld:parked')" "$cursor" \
    "the cursor must persist the configured fold contract"

  out=$(CS_CLASSIFY_RESOLVE_VERB=resolved \
    CS_CLASSIFY_BOSS_HELD_VERB=captain-held fold_inc "$f")
  full=$(CS_CLASSIFY_RESOLVE_VERB=resolved \
    CS_CLASSIFY_BOSS_HELD_VERB=captain-held fold_full "$f")
  [ "$out" = "$full" ] || fail "a fold-contract change must re-fold from scratch (inc: '$out' full: '$full')"
  assert_contains "$out" "$(printf 'choice\tneeds-decision\tpick one')" \
    "the old resolve verb must stop closing decisions after the contract changes"
  assert_contains "$out" "$(printf 'quota\tblocked\twaiting')" \
    "the old held verb must stop closing decisions after the contract changes"
  assert_grep "$(printf 'fold-contract=resolve:resolved\theld:captain-held')" "$cursor" \
    "the rewritten cursor must identify the new fold contract"
  pass "a changed resolve/held fold contract invalidates and rewrites the cursor"
}

test_same_size_replacement_refolds_via_inode_check() {
  local dir state f out full old new
  dir=$(make_case same-size); state="$dir/state"
  f="$state/t1.status"
  old='needs-decision [key=aa]: xx'
  new='needs-decision [key=bb]: yy'
  [ "${#old}" = "${#new}" ] || fail "fixture bug: replacement lines must be the same size"
  printf '%s\n' "$old" > "$f"
  fold_inc "$f" > /dev/null
  # Replace the file at the same path with SAME-SIZE content on a new inode:
  # only the device+inode identity check can catch this, not the size check.
  printf '%s\n' "$new" > "$f.new"
  mv -f "$f.new" "$f"
  out=$(fold_inc "$f")
  full=$(fold_full "$f")
  [ "$out" = "$full" ] || fail "a same-size replacement must re-fold (inc: '$out' full: '$full')"
  assert_not_contains "$out" "aa" "the replaced file's old decision must not survive"
  assert_contains "$out" "$(printf 'bb\tneeds-decision\tyy')" "the replacement's decision must be folded"
  pass "a same-size replacement is caught by the device+inode identity check"
}

test_read_failure_preserves_trusted_set_and_cursor() {
  local dir state f fakebin cursor before out
  dir=$(make_case read-failure); state="$dir/state"
  f="$state/t1.status"
  printf 'needs-decision [key=api]: pick A or B\n' > "$f"
  fold_inc "$f" > /dev/null
  cursor=$(cursor_of "$state" t1)
  before=$(cat "$cursor")
  # Append new bytes, then make stat fail: the identity read is a genuine I/O
  # error, so the call must report the already-trusted persisted set unchanged
  # and must not touch the cursor - never an empty "nothing is open".
  printf 'resolved [key=api]: never seen this turn\n' >> "$f"
  fakebin=$(cs_fakebin "$dir")
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/stat"
  chmod +x "$fakebin/stat"
  out=$(PATH="$fakebin:$PATH" fold_inc "$f")
  assert_contains "$out" "$(printf 'api\tneeds-decision\tpick A or B')" \
    "a read failure must report the trusted persisted set unchanged"
  [ "$(cat "$cursor")" = "$before" ] || fail "a read failure must not rewrite the cursor"
  # Once reads work again, the appended resolution is folded normally.
  out=$(fold_inc "$f")
  [ -z "$out" ] || fail "recovery after the read failure must fold the pending append (got: '$out')"
  pass "a read failure reports the trusted set unchanged and preserves the cursor"
}

test_failed_staged_cursor_write_preserves_previous_cursor() {
  local dir state f cursor before out
  dir=$(make_case failed-stage); state="$dir/state"
  f="$state/t1.status"
  cursor=$(cursor_of "$state" t1)
  printf 'needs-decision [key=api]: keep this cursor\n' > "$f"
  fold_inc "$f" > /dev/null
  before=$(cat "$cursor")
  : > "$f"

  out=$(fold_inc_with_failed_stage "$f")
  [ -z "$out" ] || fail "the current empty file must still fold to an empty set (got: '$out')"
  [ "$(cat "$cursor")" = "$before" ] \
    || fail "a failed staged write must preserve the complete previous cursor"
  out=$(fold_inc "$f")
  [ -z "$out" ] || fail "recovery after a failed staged write must persist the empty fold (got: '$out')"
  assert_grep 'offset=0' "$cursor" "recovery must replace the preserved cursor with the complete reset"
  pass "a failed staged cursor write preserves the previous cursor"
}

test_atomic_temp_files_ignore_predictable_symlinks() {
  local dir state f cursor read_victim write_victim out full
  dir=$(make_case temp-symlinks); state="$dir/state"
  f="$state/t1.status"
  cursor=$(cursor_of "$state" t1)
  read_victim="$dir/read-victim"
  write_victim="$dir/write-victim"
  printf 'read-safe\n' > "$read_victim"
  printf 'write-safe\n' > "$write_victim"
  printf 'needs-decision [key=api]: choose safely\n' > "$f"

  out=$(fold_inc_with_predictable_symlinks "$f" "$read_victim" "$write_victim")
  full=$(fold_full "$f")
  [ "$out" = "$full" ] || fail "atomic temp paths must preserve fold behavior (inc: '$out' full: '$full')"
  [ "$(cat "$read_victim")" = 'read-safe' ] || fail "the chunk read must not follow a predictable symlink"
  [ "$(cat "$write_victim")" = 'write-safe' ] || fail "the cursor stage must not follow a predictable symlink"
  [ ! -L "$cursor" ] || fail "the persisted cursor must be a regular file, not an attacker symlink"
  pass "atomic cursor temp files ignore predictable symlinks"
}

test_compare_before_rename_skips_observed_newer_cursor() {
  local dir state f cursor fakebin real_tail ready release slow_out slow_pid attempts=0
  local fast_out failed_read cursor_offset file_size
  dir=$(make_case concurrent); state="$dir/state"
  f="$state/t1.status"
  cursor=$(cursor_of "$state" t1)
  fakebin=$(cs_fakebin "$dir")
  real_tail=$(command -v tail)
  ready="$dir/slow-ready"
  release="$dir/slow-release"
  slow_out="$dir/slow-output"
  printf 'needs-decision [key=api]: choose one\n' > "$f"
  fold_inc "$f" > /dev/null
  printf 'working: slow writer append\n' >> "$f"

  # This pauses the slow writer before its header comparison and proves it skips
  # a newer cursor already present at comparison time. It does not exercise the
  # accepted compare-then-rename window after that check.
  cat > "$fakebin/tail" <<'SH'
#!/usr/bin/env bash
"$CS_CURSOR_REAL_TAIL" "$@" || exit $?
: > "$CS_CURSOR_RACE_READY"
while [ ! -e "$CS_CURSOR_RACE_RELEASE" ]; do
  sleep 0.01
done
SH
  chmod +x "$fakebin/tail"
  PATH="$fakebin:$PATH" \
    CS_CURSOR_REAL_TAIL="$real_tail" \
    CS_CURSOR_RACE_READY="$ready" \
    CS_CURSOR_RACE_RELEASE="$release" \
    bash -c '. "$1"; status_open_decisions_incremental "$2"' \
      _ "$CLASSIFY" "$f" > "$slow_out" &
  slow_pid=$!

  while [ ! -e "$ready" ]; do
    if ! kill -0 "$slow_pid" 2>/dev/null; then
      wait "$slow_pid" || true
      fail "the staged slow cursor writer exited before the race point"
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 500 ]; then
      : > "$release"
      wait "$slow_pid" || true
      fail "timed out staging the slow cursor writer"
    fi
    sleep 0.01
  done

  printf 'resolved [key=api]: chose one\n' >> "$f"
  fast_out=$(fold_inc "$f")
  : > "$release"
  wait "$slow_pid" || fail "the staged slow cursor writer failed"
  [ -z "$fast_out" ] || fail "the newer writer must fold the resolution (got: '$fast_out')"

  cursor_offset=$(sed -n '1s/^offset=//p' "$cursor")
  file_size=$(wc -c < "$f" | tr -d ' ')
  [ "$cursor_offset" = "$file_size" ] \
    || fail "the comparison moved an observed newer cursor backward (offset: '$cursor_offset' size: '$file_size')"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/stat"
  chmod +x "$fakebin/stat"
  failed_read=$(PATH="$fakebin:$PATH" fold_inc "$f")
  [ -z "$failed_read" ] \
    || fail "a read failure after the race must see the newer persisted closed set (got: '$failed_read')"
  pass "compare-before-rename skips an observed newer cursor"
}

test_cursor_is_safe_to_delete() {
  local dir state f out full
  dir=$(make_case delete-cursor); state="$dir/state"
  f="$state/t1.status"
  printf 'needs-review: built it\nworking: more\n' > "$f"
  fold_inc "$f" > /dev/null
  rm -f "$(cursor_of "$state" t1)"
  out=$(fold_inc "$f")
  full=$(fold_full "$f")
  [ "$out" = "$full" ] || fail "deleting the cursor must only cost one full re-fold (inc: '$out' full: '$full')"
  assert_present "$(cursor_of "$state" t1)" "the re-fold must rewrite the cursor"
  pass "deleting the cursor at any time only costs one full re-fold"
}

test_scan_wrapper_matches_full_scan() {
  local dir state inc full
  dir=$(make_case scan); state="$dir/state"
  printf 'working: a\nneeds-decision [key=one]: first\n' > "$state/alpha.status"
  printf 'blocked [key=two]: second\nresolved [key=two]: closed\n' > "$state/beta.status"
  printf 'needs-review: third\n' > "$state/gamma.status"
  full=$(bash -c '. "$1"; scan_open_decisions "$2"' _ "$CLASSIFY" "$state")
  inc=$(scan_inc "$state")
  [ "$inc" = "$full" ] || fail "the incremental scan must equal the full scan (inc: '$inc' full: '$full')"
  # And again from warm cursors, with a new append landing in the result.
  printf 'blocked [key=late]: new blocker\n' >> "$state/beta.status"
  full=$(bash -c '. "$1"; scan_open_decisions "$2"' _ "$CLASSIFY" "$state")
  inc=$(scan_inc "$state")
  [ "$inc" = "$full" ] || fail "the warm-cursor scan must equal the full scan (inc: '$inc' full: '$full')"
  assert_contains "$inc" "$(printf 'beta\tlate\tblocked\tnew blocker')" \
    "the warm scan must fold the new append"
  pass "scan_open_decisions_incremental matches scan_open_decisions cold and warm"
}

test_new_task_without_cursor_matches_full_fold
test_steady_state_folds_only_new_bytes
test_incremental_agrees_with_full_fold_line_by_line
test_truncated_log_refolds_from_scratch
test_zero_byte_invalidation_persists_reset_cursor
test_fold_contract_change_invalidates_cursor
test_same_size_replacement_refolds_via_inode_check
test_read_failure_preserves_trusted_set_and_cursor
test_failed_staged_cursor_write_preserves_previous_cursor
test_atomic_temp_files_ignore_predictable_symlinks
test_compare_before_rename_skips_observed_newer_cursor
test_cursor_is_safe_to_delete
test_scan_wrapper_matches_full_scan
