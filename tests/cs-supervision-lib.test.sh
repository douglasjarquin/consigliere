#!/usr/bin/env bash
# Behavior: characterization tests for the two sourced-never-executed supervision
# libraries.
#
# bin/cs-supervision-lib.sh (contract from its header + code):
#   cs_supervision_status <state-dir> [grace] populates, always returning 0:
#     CS_SUP_IN_FLIGHT     - count of state/*.meta
#     CS_SUP_WATCHER_FRESH - true iff .last-watcher-beat mtime is < grace old
#     CS_SUP_BEACON_DESC   - "never" (absent), "<age>s ago", or "unknown"
#     CS_SUP_QUEUE_PENDING - true iff state/.wake-queue is non-empty
#   grace defaults to $CS_GUARD_GRACE, then 300.
#   cs_supervision_unhealthy <state-dir> [grace] is true (exit 0) EXACTLY when
#   in-flight work exists AND no watcher beacon is fresh; false otherwise,
#   including a fleet with zero in-flight tasks.
#
# bin/cs-primary-scope-lib.sh (contract from its header + code):
#   cs_root_is_capo_home <root> is true iff <root>/.cs-capo-home is a real file
#   (not a symlink) holding a single non-empty id of only [A-Za-z0-9._-].
#   cs_primary_scope_matches <root> <state> is true iff the caller is at the
#     root's physical top-level path, has no task id unless <root> is a valid
#     capo home with matching CS_HOME/state, and <root> is a plain checkout
#     (git-dir == git-common-dir) OR a valid capo home, AND
#     - <root>/AGENTS.md is a file, <root>/bin is a dir, <state> is a dir.
#   A linked task worktree (git-dir != git-common-dir, no capo marker) is NOT
#   primary.
#
# Hermetic: temp state dirs and temp git repos only; no herdr/gh/network.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset CS_TASK_ID CS_ROOT_OVERRIDE CS_HOME CS_STATE_OVERRIDE CS_DATA_OVERRIDE

# shellcheck source=bin/cs-supervision-lib.sh
. "$ROOT/bin/cs-supervision-lib.sh"
# shellcheck source=bin/cs-primary-scope-lib.sh
. "$ROOT/bin/cs-primary-scope-lib.sh"

TMP=$(cs_test_tmproot cs-supervision-lib)
cs_git_identity

# --- cs_supervision_status ---------------------------------------------------

# 1. empty state: zero in-flight, no beacon, no queue.
S1="$TMP/s1"; mkdir -p "$S1"
cs_supervision_status "$S1"
[ "$CS_SUP_IN_FLIGHT" = 0 ] || fail "empty state: expected 0 in-flight, got $CS_SUP_IN_FLIGHT"
[ "$CS_SUP_WATCHER_FRESH" = false ] || fail "empty state: watcher should not be fresh"
[ "$CS_SUP_BEACON_DESC" = never ] || fail "empty state: beacon desc should be 'never', got '$CS_SUP_BEACON_DESC'"
[ "$CS_SUP_QUEUE_PENDING" = false ] || fail "empty state: queue should not be pending"
pass "cs_supervision_status on an empty state dir reports 0 in-flight, no beacon, no queue"

# 2. two metas counted as in-flight.
S2="$TMP/s2"; mkdir -p "$S2"
cs_write_meta "$S2/a.meta" "kind=ship"
cs_write_meta "$S2/b.meta" "kind=scout"
cs_supervision_status "$S2"
[ "$CS_SUP_IN_FLIGHT" = 2 ] || fail "two metas: expected 2 in-flight, got $CS_SUP_IN_FLIGHT"
pass "cs_supervision_status counts state/*.meta as in-flight tasks"

# 3. fresh beacon within grace -> watcher fresh, beacon desc "<n>s ago".
S3="$TMP/s3"; mkdir -p "$S3"
touch "$S3/.last-watcher-beat"
cs_supervision_status "$S3" 300
[ "$CS_SUP_WATCHER_FRESH" = true ] || fail "fresh beacon: watcher should be fresh"
case "$CS_SUP_BEACON_DESC" in
  *s\ ago) : ;;
  *) fail "fresh beacon: desc should be '<n>s ago', got '$CS_SUP_BEACON_DESC'" ;;
esac
pass "cs_supervision_status reports a fresh watcher beacon within the grace window"

# 4. stale beacon (older than grace) -> not fresh.
S4="$TMP/s4"; mkdir -p "$S4"
touch "$S4/.last-watcher-beat"
# Backdate the beacon well past a small grace.
back=$(( $(date +%s) - 500 ))
if [ "$(uname)" = Darwin ]; then
  touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$S4/.last-watcher-beat"
else
  touch -m -d "@$back" "$S4/.last-watcher-beat"
fi
cs_supervision_status "$S4" 300
[ "$CS_SUP_WATCHER_FRESH" = false ] || fail "stale beacon: watcher should NOT be fresh"
pass "cs_supervision_status reports a stale watcher beacon (older than grace) as not fresh"

# 5. non-empty wake queue -> queue pending.
S5="$TMP/s5"; mkdir -p "$S5"
printf '123\t1\tsignal\ta.status\tsignal: x\n' > "$S5/.wake-queue"
cs_supervision_status "$S5"
[ "$CS_SUP_QUEUE_PENDING" = true ] || fail "queue: a non-empty .wake-queue should be pending"
pass "cs_supervision_status flags a non-empty wake queue as pending"

# --- cs_supervision_unhealthy ------------------------------------------------

# 6. in-flight work with no fresh beacon -> unhealthy (true).
S6="$TMP/s6"; mkdir -p "$S6"
cs_write_meta "$S6/a.meta" "kind=ship"
cs_supervision_unhealthy "$S6" 300 && rc=0 || rc=1
[ "$rc" = 0 ] || fail "in-flight + no beacon should be unhealthy (true)"
pass "cs_supervision_unhealthy is true when in-flight work has no fresh watcher beacon"

# 7. in-flight work WITH a fresh beacon -> healthy (false).
S7="$TMP/s7"; mkdir -p "$S7"
cs_write_meta "$S7/a.meta" "kind=ship"
touch "$S7/.last-watcher-beat"
cs_supervision_unhealthy "$S7" 300 && rc=0 || rc=1
[ "$rc" = 1 ] || fail "in-flight + fresh beacon should be healthy (false)"
pass "cs_supervision_unhealthy is false when a fresh beacon covers in-flight work"

# 8. zero in-flight -> healthy (false) even with no beacon.
S8="$TMP/s8"; mkdir -p "$S8"
cs_supervision_unhealthy "$S8" 300 && rc=0 || rc=1
[ "$rc" = 1 ] || fail "zero in-flight should be healthy (false) regardless of beacon"
pass "cs_supervision_unhealthy is false for an idle fleet (zero in-flight)"

# --- armed blocking sources count as work needing supervision ----------------
# An armed state/procevent/<id>.source is not a task and has no meta, but its
# result arrives as a queued wake only a live supervision cycle will read.

# 8b. an armed source alone: counted, supervised, and unhealthy with no beacon.
S8B="$TMP/s8b"; mkdir -p "$S8B/procevent"
: > "$S8B/procevent/lavish-deadbeef.source"
cs_supervision_status "$S8B" 300
[ "$CS_SUP_IN_FLIGHT" = 0 ] || fail "armed source: expected 0 in-flight, got $CS_SUP_IN_FLIGHT"
[ "$CS_SUP_ARMED_SOURCES" = 1 ] || fail "armed source: expected 1 armed, got $CS_SUP_ARMED_SOURCES"
[ "$CS_SUP_SUPERVISED" = 1 ] || fail "armed source: expected 1 supervised, got $CS_SUP_SUPERVISED"
[ "$(cs_supervision_work_desc)" = "1 blocking source(s) armed" ] \
  || fail "armed source: work desc should name the armed source, got '$(cs_supervision_work_desc)'"
cs_supervision_unhealthy "$S8B" 300 && rc=0 || rc=1
[ "$rc" = 0 ] || fail "an armed source with no beacon should be unhealthy (true)"
pass "cs_supervision_status counts an armed blocking source as work needing supervision"

# 8c. tasks and sources together: both counted, both named.
S8C="$TMP/s8c"; mkdir -p "$S8C/procevent"
cs_write_meta "$S8C/a.meta" "kind=ship"
: > "$S8C/procevent/lavish-1.source"
: > "$S8C/procevent/lavish-2.source"
cs_supervision_status "$S8C" 300
[ "$CS_SUP_SUPERVISED" = 3 ] || fail "mixed: expected 3 supervised, got $CS_SUP_SUPERVISED"
[ "$(cs_supervision_work_desc)" = "1 task(s) in flight and 2 blocking source(s) armed" ] \
  || fail "mixed: work desc should name both, got '$(cs_supervision_work_desc)'"
pass "cs_supervision_work_desc names in-flight tasks and armed sources together"

# --- cs_root_is_capo_home ----------------------------------------------------

# 9. a valid marker file with a clean id -> true.
R9="$TMP/r9"; mkdir -p "$R9"
printf 'capo-1\n' > "$R9/.cs-capo-home"
cs_root_is_capo_home "$R9" && rc=0 || rc=1
[ "$rc" = 0 ] || fail "valid .cs-capo-home marker should be recognized"
pass "cs_root_is_capo_home accepts a real marker file with a clean id"

# 10. no marker -> false.
R10="$TMP/r10"; mkdir -p "$R10"
cs_root_is_capo_home "$R10" && rc=0 || rc=1
[ "$rc" = 1 ] || fail "absent marker should not be a capo home"
pass "cs_root_is_capo_home rejects a root with no marker"

# 11. symlinked marker -> false (never trust a symlink).
R11="$TMP/r11"; mkdir -p "$R11"
printf 'capo-1\n' > "$TMP/real-marker"
ln -s "$TMP/real-marker" "$R11/.cs-capo-home"
cs_root_is_capo_home "$R11" && rc=0 || rc=1
[ "$rc" = 1 ] || fail "a symlinked marker must be refused"
pass "cs_root_is_capo_home refuses a symlinked marker"

# 12. empty marker -> false.
R12="$TMP/r12"; mkdir -p "$R12"
: > "$R12/.cs-capo-home"
cs_root_is_capo_home "$R12" && rc=0 || rc=1
[ "$rc" = 1 ] || fail "an empty marker id must be refused"
pass "cs_root_is_capo_home refuses an empty marker id"

# 13. marker id with unsafe characters -> false.
R13="$TMP/r13"; mkdir -p "$R13"
printf 'bad/id\n' > "$R13/.cs-capo-home"
cs_root_is_capo_home "$R13" && rc=0 || rc=1
[ "$rc" = 1 ] || fail "a marker id with unsafe characters must be refused"
pass "cs_root_is_capo_home refuses a marker id containing unsafe characters"

# --- cs_primary_scope_matches ------------------------------------------------

# Build a real repo (primary checkout) with a linked task worktree.
PROJ="$TMP/proj"
WT="$TMP/wt"
cs_git_worktree "$PROJ" "$WT" cs/task-1
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
# Both roots carry the shape files so only the git-dir test can distinguish them.
for r in "$PROJ" "$WT"; do
  mkdir -p "$r/bin"
  : > "$r/AGENTS.md"
done

# 14. a plain checkout with AGENTS.md, bin/, and a state dir -> matches.
(
  cd "$PROJ" && cs_primary_scope_matches "$PROJ" "$STATE_DIR"
) && rc=0 || rc=1
[ "$rc" = 0 ] || fail "a plain primary checkout should match"
pass "cs_primary_scope_matches is true for a plain checkout with the primary shape"

# 15. a linked task worktree (no capo marker) -> does NOT match.
cs_primary_scope_matches "$WT" "$STATE_DIR" && rc=0 || rc=1
[ "$rc" = 1 ] || fail "a linked task worktree must NOT be primary"
pass "cs_primary_scope_matches is false for a linked task worktree"

# 16. missing AGENTS.md fails the plain-checkout even when git-dir is primary.
PROJ2="$TMP/proj2"
cs_git_init_commit "$PROJ2"
mkdir -p "$PROJ2/bin"
cs_primary_scope_matches "$PROJ2" "$STATE_DIR" && rc=0 || rc=1
[ "$rc" = 1 ] || fail "a primary checkout without AGENTS.md must not match"
pass "cs_primary_scope_matches requires AGENTS.md on a plain checkout"

# 17. a valid capo marker force-includes a linked worktree that otherwise fails.
printf 'capo-1\n' > "$WT/.cs-capo-home"
(
  cd "$WT" && cs_primary_scope_matches "$WT" "$STATE_DIR"
) && rc=0 || rc=1
[ "$rc" = 0 ] || fail "a capo-home worktree with the primary shape should match"
pass "cs_primary_scope_matches force-includes a valid capo home even in a linked worktree"

pass "cs-supervision-lib and cs-primary-scope-lib predicates characterized"
