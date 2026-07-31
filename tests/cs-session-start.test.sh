#!/usr/bin/env bash
# Behavior (portable): the session-start digest's startup-memory budget.
#
# data/boss.md, data/boss-shared.md, and data/learnings.md are read IN FULL at
# every session start of every home, so their size is a standing cost paid
# whether or not a session ever uses them. Unlike the registries printed beside
# them, curated prose has no natural ceiling, so without a visible bound it
# grows monotonically and the digest quietly gets more expensive forever.
#
# The digest REPORTS over-budget files and never truncates them: this script
# does not get to decide which of the boss's own preferences to drop. These
# tests pin both halves of that - the report fires, and the content survives.
#
# The digest always exits 0 and prints its context section even when the session
# lock is refused, so these cases do not depend on acquiring a lock.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(cs_test_tmproot cs-session-start)
mkdir -p "$TMP"
BIN="$ROOT/bin/cs-session-start.sh"

# fresh_home <name> -> an isolated CS_HOME with the standard subdirectories
fresh_home() {
  local h="$TMP/$1"
  rm -rf "$h"
  mkdir -p "$h/data" "$h/state" "$h/config"
  printf '%s\n' "$h"
}

# big_file <path> <approx-bytes> - fill with distinct, realistic-looking lines
big_file() {
  local path=$1 want=$2 i=0
  : > "$path"
  while [ "$(wc -c < "$path" | tr -d '[:space:]')" -lt "$want" ]; do
    i=$((i + 1))
    printf -- '- learning %s: a durable fleet-local operational fact worth keeping.\n' "$i" >> "$path"
  done
}

# --- under budget: no report --------------------------------------------------
HOME_DIR=$(fresh_home under)
printf 'The boss prefers plain outcome language.\n' > "$HOME_DIR/data/boss.md"
out=$(CS_HOME="$HOME_DIR" CS_STARTUP_MEMORY_MAX_BYTES=8192 "$BIN" 2>/dev/null)
assert_not_contains "$out" 'OVER STARTUP-MEMORY BUDGET' "a small startup-memory file is not flagged"
assert_contains "$out" 'The boss prefers plain outcome language.' "the digest still prints the file"
pass "startup memory under budget is printed without a report"

# --- over budget: reported, named, and still printed in full ------------------
HOME_DIR=$(fresh_home over)
big_file "$HOME_DIR/data/learnings.md" 12000
first_line=$(head -1 "$HOME_DIR/data/learnings.md")
last_line=$(tail -1 "$HOME_DIR/data/learnings.md")
size=$(wc -c < "$HOME_DIR/data/learnings.md" | tr -d '[:space:]')
out=$(CS_HOME="$HOME_DIR" CS_STARTUP_MEMORY_MAX_BYTES=8192 "$BIN" 2>/dev/null)
assert_contains "$out" 'OVER STARTUP-MEMORY BUDGET' "an oversized startup-memory file is reported"
assert_contains "$out" "$size bytes against a 8192-byte budget" "the report names the actual size and budget"
assert_contains "$out" '/vault' "the report names the owner that fixes it"
# A report, never a truncation: both ends of the file must still be in the digest.
assert_contains "$out" "$first_line" "an over-budget file is still printed from the top"
assert_contains "$out" "$last_line" "an over-budget file is not truncated at the end"
pass "startup memory over budget is reported by size and owner, and never truncated"

# --- the budget is per file, not for the whole context ------------------------
HOME_DIR=$(fresh_home perfile)
big_file "$HOME_DIR/data/learnings.md" 12000
printf 'Short and well curated.\n' > "$HOME_DIR/data/boss.md"
printf 'Also short.\n' > "$HOME_DIR/data/boss-shared.md"
out=$(CS_HOME="$HOME_DIR" CS_STARTUP_MEMORY_MAX_BYTES=8192 "$BIN" 2>/dev/null)
count=$(printf '%s\n' "$out" | grep -c 'OVER STARTUP-MEMORY BUDGET' || true)
[ "$count" -eq 1 ] ||
  fail "exactly the one oversized file should be reported, got $count report(s)"
pass "the budget applies per file, so a curated file is not blamed for a bloated sibling"

# --- registries are deliberately not budgeted ---------------------------------
# projects.md and capos.md are bounded by how many projects and capos exist, so
# growth there is real fleet state rather than uncurated prose.
HOME_DIR=$(fresh_home registries)
big_file "$HOME_DIR/data/projects.md" 12000
out=$(CS_HOME="$HOME_DIR" CS_STARTUP_MEMORY_MAX_BYTES=8192 "$BIN" 2>/dev/null)
assert_not_contains "$out" 'OVER STARTUP-MEMORY BUDGET' "a large registry is not a startup-memory violation"
pass "registries are outside the startup-memory budget"

# --- a malformed budget falls back instead of disabling the check -------------
HOME_DIR=$(fresh_home malformed)
big_file "$HOME_DIR/data/learnings.md" 12000
out=$(CS_HOME="$HOME_DIR" CS_STARTUP_MEMORY_MAX_BYTES=not-a-number "$BIN" 2>/dev/null)
assert_contains "$out" 'against a 8192-byte budget' "a malformed budget falls back to the default"
pass "a malformed budget falls back to the default rather than silently disabling the check"

pass "cs-session-start startup-memory budget"
