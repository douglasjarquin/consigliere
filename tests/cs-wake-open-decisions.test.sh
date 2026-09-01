#!/usr/bin/env bash
# tests/cs-wake-open-decisions.test.sh - the fleet-wide OPEN DECISIONS section
# that cs-wake-drain.sh prints on every drain. A needs-decision/needs-review/
# blocked line buried under later unrelated status appends is only visible
# through the last-line wake annotation, so a still-open decision could go
# silently missed. These cases prove the section surfaces every still-open keyed
# decision (empty-queue fast path AND non-empty drain), never a resolved one,
# skips an unreadable or symlinked status file without stderr noise, stays quiet
# on a clean drain, and leaves the existing raw-row/annotation behavior intact.
# They also exercise the classify-lib fold wrapper (scan_open_decisions) and the
# directory-wide file-handling guards on status_open_decisions directly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRAIN="$ROOT/bin/cs-wake-drain.sh"
CLASSIFY="$ROOT/bin/cs-classify-lib.sh"

TMP_ROOT=$(cs_test_tmproot cs-wake-open-decisions)

# cs-wake-drain.sh calls cs-guard.sh on every drain; point its worktree-tangle
# check at a fresh non-git dir so a feature-branch test checkout does not emit a
# spurious banner (mirrors cs-wake-queue.test.sh).
CS_ROOT_OVERRIDE="$TMP_ROOT/tangle-root"
mkdir -p "$CS_ROOT_OVERRIDE"
export CS_ROOT_OVERRIDE

make_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  printf '%s\n' "$dir"
}

# run_drain <state> <stdout-file> <stderr-file>: drain scoped to <state>.
run_drain() {
  local state=$1 out=$2 err=$3
  CS_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err"
}

# append_wake <state> <kind> <key> <payload>: enqueue via the production library.
append_wake() {
  local state=$1 kind=$2 key=$3 payload=$4
  CS_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"; cs_wake_append "$2" "$3" "$4"
  ' _ "$ROOT/bin/cs-wake-lib.sh" "$kind" "$key" "$payload"
}

# scan_wrapper <state>: the fleet-wide fold wrapper, run in a clean subshell.
scan_wrapper() {
  bash -c '. "$1"; scan_open_decisions "$2"' _ "$CLASSIFY" "$1"
}

# fold_one <status-file>: the single-file fold, run in a clean subshell.
fold_one() {
  bash -c '. "$1"; status_open_decisions "$2"' _ "$CLASSIFY" "$1"
}

test_buried_decision_surfaces_on_empty_drain() {
  local dir state out err
  dir=$(make_case buried-empty); state="$dir/state"
  out="$dir/out"; err="$dir/err"
  # A still-open decision pushed off the last line by later unrelated appends.
  printf 'working: start\nneeds-decision [key=api]: pick A or B\nworking: more\ndone: unrelated finish\n' \
    > "$state/t1.status"
  run_drain "$state" "$out" "$err" || fail "empty-queue drain failed"
  assert_grep "OPEN DECISIONS" "$out" "empty-queue drain must print the section header"
  assert_grep "t1 [key=api] needs-decision: pick A or B" "$out" \
    "a buried needs-decision must appear on the empty-queue fast path"
  pass "buried decision surfaces in OPEN DECISIONS on the empty-queue fast path"
}

test_resolved_decision_absent() {
  local dir state out err
  dir=$(make_case resolved-absent); state="$dir/state"
  out="$dir/out"; err="$dir/err"
  printf 'blocked [key=x]: waiting on input\nresolved [key=x]: input arrived\n' > "$state/t2.status"
  run_drain "$state" "$out" "$err" || fail "drain failed"
  assert_no_grep "key=x" "$out" "a resolved decision must not appear in the section"
  assert_no_grep "OPEN DECISIONS" "$out" "no open decisions must leave the section silent"
  pass "a resolved decision is folded out and the clean drain stays quiet"
}

test_nonempty_drain_preserves_raw_and_annotations() {
  local dir state out err
  dir=$(make_case nonempty); state="$dir/state"
  out="$dir/out"; err="$dir/err"
  printf 'needs-decision [key=api]: pick A or B\ndone: unrelated finish\n' > "$state/t1.status"
  append_wake "$state" signal t1.status "signal: $state/t1.status" || fail "append failed"
  run_drain "$state" "$out" "$err" || fail "non-empty drain failed"
  # Existing behavior: the raw dedup row and the last-line annotation still print.
  assert_grep "$(printf '\tsignal\tt1.status\t')" "$out" "raw wake row must still print"
  assert_grep "wake annotation:" "$out" "the last-line annotation must still print"
  # And the new section surfaces the decision the last line no longer shows.
  assert_grep "t1 [key=api] needs-decision: pick A or B" "$out" \
    "the buried decision must also surface on a non-empty drain"
  pass "non-empty drain keeps raw rows and annotations and adds the section"
}

test_unreadable_and_symlink_skipped_without_noise() {
  local dir state out err
  dir=$(make_case skip-quietly); state="$dir/state"
  out="$dir/out"; err="$dir/err"
  # A real open decision that must still appear.
  printf 'needs-review: built the thing\n' > "$state/real.status"
  # A symlinked status file: skipped by the [ -L ] guard, never duplicated.
  ln -s "$state/real.status" "$state/link.status"
  # An unreadable status file: skipped silently, no redirection error on stderr.
  printf 'needs-decision [key=z]: never readable\n' > "$state/locked.status"
  chmod 000 "$state/locked.status"
  run_drain "$state" "$out" "$err"
  chmod 644 "$state/locked.status"
  assert_grep "real [key=default] needs-review: built the thing" "$out" \
    "the readable open decision must appear"
  assert_no_grep "link " "$out" "a symlinked status file must not produce its own line"
  assert_no_grep "locked" "$out" "an unreadable status file must not appear"
  [ ! -s "$err" ] || fail "unreadable/symlinked status files must not leak stderr noise: $(cat "$err")"
  pass "unreadable and symlinked status files are skipped without stderr noise"
}

test_clean_drain_prints_no_section() {
  local dir state out err
  dir=$(make_case clean); state="$dir/state"
  out="$dir/out"; err="$dir/err"
  printf 'working: humming along\n' > "$state/t1.status"
  run_drain "$state" "$out" "$err" || fail "clean drain failed"
  assert_no_grep "OPEN DECISIONS" "$out" "a drain with no open decisions must add no section noise"
  pass "a clean drain prints no OPEN DECISIONS section"
}

test_invalid_cap_falls_back_to_default() {
  local dir state out err override
  dir=$(make_case invalid-cap); state="$dir/state"
  out="$dir/out"; err="$dir/err"
  for i in $(seq 1 33); do
    printf 'needs-decision [key=k%s]: decision %s\n' "$i" "$i"
  done > "$state/t1.status"
  for override in abc 0 ''; do
    CS_OPEN_DECISIONS_CAP="$override" CS_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" \
      || fail "drain failed for invalid cap '$override'"
    assert_grep "k32" "$out" "invalid cap '$override' must retain the default bound"
    assert_no_grep "k33" "$out" "invalid cap '$override' must not disable the bound"
    assert_grep "1 more open decision(s) omitted" "$out" \
      "invalid cap '$override' must preserve the omission marker"
    [ ! -s "$err" ] || fail "invalid cap '$override' leaked stderr: $(cat "$err")"
  done
  pass "unset, empty, and non-positive caps fall back to the default"
}

test_scan_wrapper_folds_whole_fleet() {
  local dir state out
  dir=$(make_case wrapper); state="$dir/state"
  printf 'working: a\nneeds-decision [key=one]: first\n' > "$state/alpha.status"
  printf 'blocked [key=two]: second\nresolved [key=two]: closed\n' > "$state/beta.status"
  printf 'needs-review: third\n' > "$state/gamma.status"
  out=$(scan_wrapper "$state")
  assert_contains "$out" "$(printf 'alpha\tone\tneeds-decision\tfirst')" \
    "wrapper must fold an open decision from alpha"
  assert_contains "$out" "$(printf 'gamma\tdefault\tneeds-review\tthird')" \
    "wrapper must fold gamma's default-keyed open decision"
  assert_not_contains "$out" "beta" "wrapper must not emit beta's resolved decision"
  pass "scan_open_decisions folds every task and drops resolved decisions"
}

test_fold_guards_symlink_and_unreadable() {
  local dir state out
  dir=$(make_case fold-guards); state="$dir/state"
  # Symlink to a file with a real open decision: the [ -L ] guard skips it.
  printf 'needs-decision [key=k]: open\n' > "$state/target.status"
  ln -s "$state/target.status" "$state/sym.status"
  out=$(fold_one "$state/sym.status" 2> "$dir/sym.err")
  [ -z "$out" ] || fail "a symlinked status file must fold to nothing (got: $out)"
  [ ! -s "$dir/sym.err" ] || fail "symlink skip must be silent: $(cat "$dir/sym.err")"
  # Unreadable regular file: skipped silently, no redirection error.
  printf 'blocked [key=k]: open\n' > "$state/locked.status"
  chmod 000 "$state/locked.status"
  out=$(fold_one "$state/locked.status" 2> "$dir/locked.err")
  chmod 644 "$state/locked.status"
  [ -z "$out" ] || fail "an unreadable status file must fold to nothing (got: $out)"
  [ ! -s "$dir/locked.err" ] || fail "unreadable skip must be silent: $(cat "$dir/locked.err")"
  pass "status_open_decisions skips symlinked and unreadable files silently"
}

# The per-item cut comes from bin/cs-line-cap-lib.sh, shared with the
# session-start digest's status tails so one truncation marker means the same
# thing wherever an agent meets it. This pins the drain's own end of that
# contract: the lede survives, the marker appears, and the item stays inside
# the shared 220-character cap.
test_over_long_decision_note_is_capped_with_a_marker() {
  local dir state out err line item longest
  dir=$(make_case long-note); state="$dir/state"
  out="$dir/out"; err="$dir/err"
  {
    printf 'needs-decision [key=api-shape]: pick REST or RPC'
    awk 'BEGIN { while (i++ < 200) printf " and-then-some" }'
    printf '\n'
  } > "$state/task-long.status"

  run_drain "$state" "$out" "$err" || fail "drain failed on an over-long decision note"

  line=$(grep -F 'task-long' "$out")
  case "$line" in
    *'task-long [key=api-shape] needs-decision: pick REST or RPC'*' [truncated]') : ;;
    *) fail "an over-long decision note was not capped with its lede intact: $line" ;;
  esac
  item=${line#"${line%%[![:space:]]*}"}
  longest=${#item}
  [ "$longest" -le 220 ] || fail "a capped decision item ran $longest characters past the 220-character cap"

  printf 'needs-decision [key=short]: brief enough to keep whole\n' > "$state/task-short.status"
  run_drain "$state" "$out" "$err" || fail "drain failed on a short decision note"
  assert_grep 'task-short [key=short] needs-decision: brief enough to keep whole' "$out" \
    "a decision note already under the cap was altered"
  assert_no_grep 'brief enough to keep whole [truncated]' "$out" \
    "a decision note already under the cap was marked truncated"

  pass "an over-long open decision is cut to the shared cap with the shared truncation marker"
}

# The section is the moment an answer gets written, so it names the command that
# both answers a listed decision and closes it (bin/cs-send.sh --resolve-key).
# Without that, closure depends on the soldier appending a matching resolved line,
# whose next event is normally a key in a different namespace.
test_section_prints_the_answer_with_close_hint() {
  local dir state out err
  dir=$(make_case close-hint); state="$dir/state"
  out="$dir/out"; err="$dir/err"
  printf 'needs-decision [key=api]: pick A or B\n' > "$state/t1.status"
  run_drain "$state" "$out" "$err" || fail "drain failed"
  assert_grep "bin/cs-send.sh <task> --resolve-key <key>" "$out" \
    "the section must name the answer-with-close command"
  printf 'resolved [key=api]: went with A\n' >> "$state/t1.status"
  run_drain "$state" "$out" "$err" || fail "second drain failed"
  assert_no_grep "--resolve-key" "$out" \
    "a drain with no open decisions must not print the hint"
  pass "the OPEN DECISIONS section prints the answer-with-close hint at the point of use"
}

# A capo escalation is not just a message: it opens a durable keyed decision here.
# Before the pending-reply library closed its own escalations, a request the capo
# had already answered kept surfacing in every later drain.
test_resolved_pending_reply_escalation_leaves_the_section() {
  local dir state out err corr
  dir=$(make_case pending-reply); state="$dir/state"
  out="$dir/out"; err="$dir/err"
  corr=$(bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    export CS_PENDING_REPLY_NOW=1000 CS_PENDING_REPLY_GRACE_SECS=0
    corr=$(cs_pending_reply_create "$2" "$3" capo1 "why is the lane idle")
    cs_pending_reply_mark_delivered "$3" "$corr"
    cs_pending_reply_mark_turn_completed "$3" "$corr" request
    cs_pending_reply_mark_turn_completed "$3" "$corr" recovery
    cs_pending_reply_set "$(cs_pending_reply_path "$3" "$corr")" phase recovery_sent
    cs_pending_reply_maybe_escalate "$3" "$corr" >/dev/null || exit 1
    printf "%s" "$corr"
  ' _ "$ROOT/bin/cs-pending-reply-lib.sh" "$dir" "$state") \
    || fail "escalation fixture failed"
  [ -n "$corr" ] || fail "escalation fixture produced no correlation id"

  run_drain "$state" "$out" "$err" || fail "drain over an escalation failed"
  assert_grep "capo1 [key=pending-reply-$corr] blocked: pending-reply-missed" "$out" \
    "an open capo escalation must surface as a keyed open decision"

  printf 'done [corr=%s]: the lane was waiting on CI\n' "$corr" >> "$state/capo1.status"
  bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"; CS_PENDING_REPLY_NOW=2000 cs_pending_reply_try_resolve "$2" "$3"
  ' _ "$ROOT/bin/cs-pending-reply-lib.sh" "$state" "$corr" \
    || fail "the correlated capo report should resolve the record"

  run_drain "$state" "$out" "$err" || fail "drain after the resolve failed"
  assert_no_grep "pending-reply-missed" "$out" \
    "a settled capo request must stop surfacing as an open decision"
  pass "a resolved capo escalation leaves the OPEN DECISIONS section"
}

# A key stated AFTER the verb colon (needs-decision: [key=x] note) must open
# and close key x, not fold into the "default" bucket - the common worker shape
# that let two decisions collapse into one record and refused --resolve-key.
test_note_head_key_opens_and_closes() {
  local dir state f rows
  dir=$(make_case note-head-key); state="$dir/state"
  f="$state/nh.status"
  printf 'needs-decision: [key=api-shape] pick a shape\nneeds-decision [key=other]: second\n' > "$f"
  rows=$(fold_one "$f")
  assert_contains "$rows" "$(printf 'api-shape\tneeds-decision\tpick a shape')" \
    "a note-head [key=] token must open its stated key with the token stripped from the note"
  assert_contains "$rows" "$(printf 'other\tneeds-decision\tsecond')" \
    "the before-colon key position must keep working alongside"
  printf 'resolved: [key=api-shape] chosen\n' >> "$f"
  rows=$(fold_one "$f")
  case "$rows" in
    *api-shape*) fail "a note-head [key=] resolve did not close its stated key" ;;
  esac
  printf 'needs-decision: [key=bad slug] malformed\n' >> "$f"
  rows=$(fold_one "$f")
  case "$rows" in
    *default*malformed*) fail "a malformed note-head slug must reject the line, not fold to default" ;;
  esac
  pass "a [key=] token at the head of the note opens and closes its stated key"
}

# Bracket tags and the bare pending-reply corr token between the verb and the
# colon must not hide the verb: a correlated opener opens and a correlated
# closer closes, in both tag orders and both token shapes.
test_metadata_tags_do_not_hide_the_verb() {
  local dir state f rows
  dir=$(make_case corr-tags); state="$dir/state"
  f="$state/ct.status"
  printf 'needs-decision [corr=0123456789abcdef] [key=x]: pick\nblocked corr=0123456789abcdef: stuck on creds\n' > "$f"
  rows=$(fold_one "$f")
  assert_contains "$rows" "$(printf 'x\tneeds-decision\tpick')" \
    "a bracketed corr tag before the key token must not hide the opener verb"
  assert_contains "$rows" "$(printf 'default\tblocked\tstuck on creds')" \
    "a bare corr token must not hide the opener verb"
  printf 'resolved [key=x] corr=0123456789abcdef: answered\nresolved [corr=0123456789abcdef]: unblocked\n' >> "$f"
  rows=$(fold_one "$f")
  [ -z "$rows" ] || fail "correlated closers did not close their decisions: $rows"
  printf 'needs-decision free text with a=b equals: prose\n' >> "$f"
  rows=$(fold_one "$f")
  [ -z "$rows" ] || fail "free text carrying an equals sign must not fold as a verb: $rows"
  pass "correlation tags in either shape fold openers and closers correctly"
}

# A cursor persisted under the previous fold contract carries an open set
# computed while note-head keys and tagged verbs were invisible; the version
# in the fold contract must force a clean full re-fold from the log.
test_stale_fold_contract_cursor_is_rebuilt() {
  local dir state f rows
  dir=$(make_case stale-fold-cursor); state="$dir/state"
  f="$state/sc.status"
  printf 'needs-decision [corr=0123456789abcdef]: correlated question\n' > "$f"
  printf 'offset=%s\nident=%s\nfold-contract=resolve:resolved\theld:captain-held\n' \
    "$(wc -c < "$f" | tr -d '[:space:]')" \
    "$(bash -c '. "$1"; _cs_decision_file_ident "$2"' _ "$CLASSIFY" "$f")" \
    > "$state/.decision-cursor-sc"
  rows=$(bash -c '. "$1"; status_open_decisions_incremental "$2"' _ "$CLASSIFY" "$f")
  assert_contains "$rows" "$(printf 'default\tneeds-decision\tcorrelated question')" \
    "an old-contract cursor must be rebuilt from byte 0 so the correlated opener is visible"
  pass "a cursor persisted under the old fold contract is invalidated and re-folded"
}

# Every unread status line since the presentation cursor is surfaced on drain:
# an older note followed by a newer line must not vanish because only the
# newest was annotated, and an already-presented span stays quiet.
test_drain_presents_every_unread_status_line() {
  local dir state out err f
  dir=$(make_case unread-notes); state="$dir/state"
  out="$dir/out"; err="$dir/err"
  f="$state/notes.status"
  printf 'note: the answer you asked for\nworking: moving on\n' > "$f"
  printf 0 > "$state/.last-presented-notes"
  append_wake "$state" signal notes.status "signal: $f" || fail "enqueue failed"
  run_drain "$state" "$out" "$err" || fail "drain failed"
  assert_grep "unread status event: notes.status: note: the answer you asked for" "$out" \
    "the older note: line must be presented, not dropped for the newer line"
  assert_grep "unread status event: notes.status: working: moving on" "$out" \
    "the newer line must be presented too"
  append_wake "$state" signal notes.status "signal: $f" || fail "second enqueue failed"
  run_drain "$state" "$out" "$err" || fail "second drain failed"
  assert_no_grep "note: the answer you asked for" "$out" \
    "an already-presented span must not be re-announced"
  pass "the drain presents every unread status line exactly once"
}

test_note_head_key_opens_and_closes
test_metadata_tags_do_not_hide_the_verb
test_stale_fold_contract_cursor_is_rebuilt
test_drain_presents_every_unread_status_line
test_buried_decision_surfaces_on_empty_drain
test_over_long_decision_note_is_capped_with_a_marker
test_section_prints_the_answer_with_close_hint
test_resolved_pending_reply_escalation_leaves_the_section
test_resolved_decision_absent
test_nonempty_drain_preserves_raw_and_annotations
test_unreadable_and_symlink_skipped_without_noise
test_clean_drain_prints_no_section
test_invalid_cap_falls_back_to_default
test_scan_wrapper_folds_whole_fleet
test_fold_guards_symlink_and_unreadable
