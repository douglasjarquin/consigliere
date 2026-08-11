#!/usr/bin/env bash
# Behavior (portable): bin/cs-timing-lib.sh, the single owner of consigliere's
# elapsed-time records.
#
# The properties pinned here are the ones a reader of a published timeline
# depends on:
#   - it is inert until a run asks for it, so a script that merely sources the
#     library pays nothing and writes nothing;
#   - every record in a run counts its offset from ONE origin, including records
#     written by a child process, which is what makes a nested record provably
#     fall inside its parent's window instead of merely looking like it does;
#   - a value carrying whitespace is REFUSED rather than cleaned up, so a command
#     line, an environment dump, or a captured error message cannot reach the
#     file through a caller that passed the wrong variable;
#   - timing a command never changes its exit status, because instrumentation
#     that can change what it measures is worse than none.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/cs-timing-lib.sh
. "$ROOT/bin/cs-timing-lib.sh"

TMP=$(cs_test_tmproot cs-timing-lib)
mkdir -p "$TMP"

field() {  # <line> <1-based field>
  printf '%s\n' "$1" | cut -f "$2"
}

# --- inert until a run asks for it -------------------------------------------
unset CS_TIMING_FILE CS_TIMING_ORIGIN
INERT="$TMP/inert"
: > "$INERT"
rc=0
cs_timed some-step '' bash -c 'exit 3' || rc=$?
expect_code 3 "$rc" "cs_timed changed the exit status of the command it timed"
cs_timing_record some-step '' 1000 2000 || fail "an inactive record must be a silent no-op"
[ ! -s "$INERT" ] || fail "recording wrote a file before any run asked for it"
! cs_timing_active || fail "recording reported itself active with no run asking for it"
pass "recording is inert until a run asks for it"

# --- a run that asks for it gets one record per timed owner -------------------
FILE="$TMP/timings"
cs_timing_begin "$FILE" || fail "cs_timing_begin refused a writable file"
cs_timing_active || fail "a run that began recording is not active"

inner_step() { cs_timed clone-refresh someproj true; }
outer_step() { inner_step; }
cs_timed clone-refresh '' outer_step || fail "timing a shell function changed its result"

count=$(grep -c . "$FILE" || true)
[ "$count" = 2 ] || fail "expected one record per timed owner, got $count"
parent=$(awk -F'\t' '$4 == "-"' "$FILE")
child=$(awk -F'\t' '$4 == "someproj"' "$FILE")
[ -n "$parent" ] && [ -n "$child" ] \
  || fail "the timed owner and the item inside it did not both record"
[ "$(field "$child" 3)" = clone-refresh ] || fail "the record lost its step name"
[ "$(field "$child" 4)" = someproj ] || fail "the record lost the item it names"
pass "a run that asks for recording gets one record per timed owner"

# --- offsets come from one origin, so nesting is provable --------------------
p_off=$(field "$parent" 1); p_len=$(field "$parent" 2)
c_off=$(field "$child" 1); c_len=$(field "$child" 2)
for value in "$p_off" "$p_len" "$c_off" "$c_len"; do
  case "$value" in ''|*[!0-9]*) fail "a record carried a non-numeric column: $value" ;; esac
done
[ "$c_off" -ge "$p_off" ] || fail "the item started before the owner that contains it"
[ "$((c_off + c_len))" -le "$((p_off + p_len))" ] \
  || fail "the item outlived the owner that contains it, so the two used different origins"
pass "every offset counts from one origin, so a nested record falls inside its parent"

# --- a child process shares that same origin ---------------------------------
# The stage records across process boundaries (the deferred worker's checks run
# in bin/cs-bootstrap.sh and its children), so the origin has to travel with the
# environment rather than being re-derived per process. A child that re-derived
# its own origin would report an offset near zero no matter when it ran, so the
# child must land at least the slept second after the origin. A full second is
# the smallest delay the whole-second date fallback clock can still see.
sleep 1
cat > "$TMP/child.sh" <<SH
#!/usr/bin/env bash
set -u
. "$ROOT/bin/cs-timing-lib.sh"
cs_timed capo-sync somecapo true
SH
chmod +x "$TMP/child.sh"
"$TMP/child.sh" || fail "the child process failed"
child_record=$(grep 'somecapo$' "$FILE") || fail "a child process recorded nothing"
child_off=$(field "$child_record" 1)
[ "$child_off" -ge 1000 ] \
  || fail "the child re-derived its own origin instead of sharing the run's"
pass "a child process records against the run's one shared origin"

# --- whitespace in an identity is refused, never repaired --------------------
before=$(grep -c . "$FILE" || true)
rc=0
cs_timing_record clone-refresh 'two words' 1000 2000 || rc=$?
[ "$rc" -ne 0 ] || fail "a detail carrying whitespace was accepted"
rc=0
cs_timing_record 'two words' '' 1000 2000 || rc=$?
[ "$rc" -ne 0 ] || fail "a step name carrying whitespace was accepted"
after=$(grep -c . "$FILE" || true)
[ "$before" = "$after" ] || fail "a refused value was written anyway, repaired or not"
assert_no_grep 'two words' "$FILE" "a whitespace-bearing value reached the record file"

# The same refusal through cs_timed: the command still runs, its status is still
# its own, and the record is the only thing lost.
rc=0
cs_timed clone-refresh 'two words' bash -c 'exit 5' || rc=$?
expect_code 5 "$rc" "a refused record changed the exit status of the command it timed"
after=$(grep -c . "$FILE" || true)
[ "$before" = "$after" ] || fail "cs_timed wrote a record it should have refused"
pass "a value carrying whitespace is refused rather than cleaned up"

# --- the printed timeline is ordered by start, not by write order ------------
# Records are appended when a step FINISHES, so an owner that contains items is
# written after them. The reader is owed a timeline, so the printer sorts.
ORDERED="$TMP/ordered"
printf '%s\n' \
  '900	10	capo-liveness	late' \
  '0	1200	clone-refresh	-' \
  '30	40	clone-refresh	early' > "$ORDERED"
printed=$(cs_timing_print "$ORDERED")
first=$(printf '%s\n' "$printed" | sed -n 1p)
last=$(printf '%s\n' "$printed" | sed -n 3p)
assert_contains "$first" '+0ms' "the timeline did not start at the earliest offset"
assert_contains "$last" 'capo-liveness late' "the timeline did not end at the latest offset"
assert_not_contains "$first" ' - ' "a record naming no item printed its placeholder detail"
cs_timing_print "$TMP/nothing-here" && fail "printing an absent timeline reported success"
pass "the printed timeline is ordered by start, so it reads as a timeline"

pass "cs-timing-lib elapsed-time records"
