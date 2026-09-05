#!/usr/bin/env bash
# Behavior (portable): bin/cs-meta-lib.sh's helper contracts -
# cs_meta_endpoint_generation_rotation_lines carries every prior
# endpoint-generation pair forward across a cs_meta_write full-overwrite, so a
# capo respawn never orphans a message queued against an earlier generation;
# cs_meta_home falls back to parent_home for any task (ordinary, non-capo)
# whose meta never records its own home=.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$ROOT/bin/cs-meta-lib.sh"

if ! declare -F cs_meta_endpoint_generation_rotation_lines >/dev/null 2>&1; then
  fail "cs-meta-lib.sh must expose cs_meta_endpoint_generation_rotation_lines"
fi

TMP=$(cs_test_tmproot cs-meta-lib)

# --- case 1: no existing file -> bare endpoint_generation line only --------
out=$(cs_meta_endpoint_generation_rotation_lines "$TMP/nonexistent.meta" gen-1)
[ "$out" = "endpoint_generation=gen-1" ] ||
  fail "a brand-new meta must write only endpoint_generation, no previous_ fields (got: $out)"
pass "first-ever generation writes no previous_endpoint_generation lines"

# --- case 2: single prior value, adjacent pair emitted ---------------------
cs_write_meta "$TMP/single.meta" "endpoint_generation=gen-1"
out=$(cs_meta_endpoint_generation_rotation_lines "$TMP/single.meta" gen-2)
mapfile -t lines <<<"$out"
[ "${#lines[@]}" -eq 3 ] || fail "single-rotation output must be exactly 3 lines (got ${#lines[@]}): $out"
[ "${lines[0]}" = "previous_endpoint_generation=gen-1" ] || fail "line 1 must carry the old generation: ${lines[0]}"
case "${lines[1]}" in
  previous_endpoint_generation_at=*) : ;;
  *) fail "line 2 must be the adjacent previous_endpoint_generation_at pair: ${lines[1]}" ;;
esac
[ "${lines[2]}" = "endpoint_generation=gen-2" ] || fail "line 3 must be the new generation: ${lines[2]}"
pass "single rotation preserves lineage as an adjacent pair"

# Fold case 2's output into a fresh meta and confirm the OLD generation still
# validates - this is the read-side contract the write-side must satisfy.
cs_write_meta "$TMP/single-rotated.meta" "$out"
cs_meta_endpoint_generation_known "$TMP/single-rotated.meta" gen-1 "$(date +%s)" ||
  fail "a message asserting the pre-rotation generation must still validate"
pass "post-rotation meta validates a message asserting the pre-rotation generation"

# --- case 3: two respawns in a row must not drop generation N-2 -----------
# Simulates a capo already respawned once (gen-1 -> gen-2, previous_ pair
# already on file) being respawned a second time (-> gen-3). The exact gap
# Metis review caught in the first draft of this fix: a helper that only
# carries forward the SINGLE most recent pair loses gen-1's history here.
cs_write_meta "$TMP/double.meta" \
  "previous_endpoint_generation=gen-1" \
  "previous_endpoint_generation_at=1000" \
  "endpoint_generation=gen-2"
out=$(cs_meta_endpoint_generation_rotation_lines "$TMP/double.meta" gen-3)
assert_contains "$out" "previous_endpoint_generation=gen-1" "gen-1's history must survive a second respawn"
assert_contains "$out" "previous_endpoint_generation=gen-2" "the just-superseded gen-2 must also be recorded"
assert_contains "$out" "endpoint_generation=gen-3" "the new generation must be recorded"
cs_write_meta "$TMP/double-rotated.meta" "$out"
cs_meta_endpoint_generation_known "$TMP/double-rotated.meta" gen-1 1000 ||
  fail "a message asserting the generation from TWO respawns ago must still validate"
pass "two respawns in a row still preserve the oldest generation's history"

# --- adjacency guard: the helper never separates a pair with another key --
# cs_meta_endpoint_generation_known's reader pairs a previous_endpoint_generation
# line with only the very next previous_endpoint_generation_at line, silently
# dropping an unpaired one - so the helper's own output must never place two
# previous_endpoint_generation lines back to back with no _at between them.
mapfile -t double_lines <<<"$out"
prev_seen=0
for line in "${double_lines[@]}"; do
  case "$line" in
    previous_endpoint_generation=*)
      [ "$prev_seen" -eq 0 ] || fail "two previous_endpoint_generation lines appeared with no _at between them: $out"
      prev_seen=1
      ;;
    previous_endpoint_generation_at=*)
      [ "$prev_seen" -eq 1 ] || fail "a previous_endpoint_generation_at line appeared with no preceding pair: $out"
      prev_seen=0
      ;;
  esac
done
pass "rotation-lines output never separates a previous_ pair"

pass "cs_meta_endpoint_generation_rotation_lines contract"

cs_write_meta "$TMP/ordinary.meta" "kind=ship" "parent_home=/tmp/fake-root"
result=$(cs_meta_home "$TMP/ordinary.meta") || fail "cs_meta_home should succeed when parent_home is set"
[ "$result" = "/tmp/fake-root" ] || fail "cs_meta_home should fall back to parent_home when home is unset"
pass "cs_meta_home falls back to parent_home when home is unset"

cs_write_meta "$TMP/capo.meta" "kind=capo" "home=/tmp/fake-capo-home" "parent_home=/tmp/fake-root"
result=$(cs_meta_home "$TMP/capo.meta") || fail "cs_meta_home should succeed when home is set"
[ "$result" = "/tmp/fake-capo-home" ] || fail "cs_meta_home should return the literal home value when set, ignoring parent_home"
pass "cs_meta_home returns the literal home value when set"

cs_write_meta "$TMP/bare.meta" "kind=ship"
if result=$(cs_meta_home "$TMP/bare.meta" 2>/dev/null); then
  fail "cs_meta_home should fail when neither home nor parent_home is recorded"
fi
[ -z "$result" ] || fail "cs_meta_home should print nothing when neither home nor parent_home is recorded"
pass "cs_meta_home degrades to a failure when neither home nor parent_home is recorded"

pass "cs_meta_home capo-only fallback contract"
