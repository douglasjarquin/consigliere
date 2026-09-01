#!/usr/bin/env bash
# Behavior (portable): the session-start digest's startup-memory budget,
# truncation-safe section ordering, per-line status-tail cap, and the
# recovery-input backlog composition on both backlog backends.
#
# config/boss.md, config/boss-shared.md, and config/learnings.md are read IN FULL at
# every session start of every home, so their size is a standing cost paid
# whether or not a session ever uses them. Unlike the registries printed beside
# them, curated prose has no natural ceiling, so without a visible bound it
# grows monotonically and the digest quietly gets more expensive forever.
#
# The digest REPORTS over-budget files and never truncates them: this script
# does not get to decide which of the boss's own preferences to drop. These
# tests pin both halves of that - the report fires, and the content survives.
#
# The digest is delivered through a harness that truncates an oversized payload
# from the TAIL, so section order decides what a truncated startup loses: the
# safety preamble stays pinned, live fleet state precedes the curated memory a
# truncated tail may take, and the read-once contract precedes both.
#
# The digest always exits 0 and prints its context section even when the session
# lock is refused, so these cases do not depend on acquiring a lock. The single
# exception is bootstrap's fatal BASH_FLOOR blocker, pinned at the end of this
# file: that one refuses the session with a non-zero exit.
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
printf 'The boss prefers plain outcome language.\n' > "$HOME_DIR/config/boss.md"
out=$(CS_HOME="$HOME_DIR" CS_STARTUP_MEMORY_MAX_BYTES=8192 "$BIN" 2>/dev/null)
assert_not_contains "$out" 'OVER STARTUP-MEMORY BUDGET' "a small startup-memory file is not flagged"
assert_contains "$out" 'The boss prefers plain outcome language.' "the digest still prints the file"
pass "startup memory under budget is printed without a report"

# --- over budget: reported, named, and still printed in full ------------------
HOME_DIR=$(fresh_home over)
big_file "$HOME_DIR/config/learnings.md" 12000
first_line=$(head -1 "$HOME_DIR/config/learnings.md")
last_line=$(tail -1 "$HOME_DIR/config/learnings.md")
size=$(wc -c < "$HOME_DIR/config/learnings.md" | tr -d '[:space:]')
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
big_file "$HOME_DIR/config/learnings.md" 12000
printf 'Short and well curated.\n' > "$HOME_DIR/config/boss.md"
printf 'Also short.\n' > "$HOME_DIR/config/boss-shared.md"
out=$(CS_HOME="$HOME_DIR" CS_STARTUP_MEMORY_MAX_BYTES=8192 "$BIN" 2>/dev/null)
count=$(printf '%s\n' "$out" | grep -c 'OVER STARTUP-MEMORY BUDGET' || true)
[ "$count" -eq 1 ] ||
  fail "exactly the one oversized file should be reported, got $count report(s)"
pass "the budget applies per file, so a curated file is not blamed for a bloated sibling"

# --- registries are deliberately not budgeted ---------------------------------
# projects.md and capos.md are bounded by how many projects and capos exist, so
# growth there is real fleet state rather than uncurated prose.
HOME_DIR=$(fresh_home registries)
big_file "$HOME_DIR/config/projects.md" 12000
out=$(CS_HOME="$HOME_DIR" CS_STARTUP_MEMORY_MAX_BYTES=8192 "$BIN" 2>/dev/null)
assert_not_contains "$out" 'OVER STARTUP-MEMORY BUDGET' "a large registry is not a startup-memory violation"
pass "registries are outside the startup-memory budget"

# --- a malformed budget falls back instead of disabling the check -------------
HOME_DIR=$(fresh_home malformed)
big_file "$HOME_DIR/config/learnings.md" 12000
out=$(CS_HOME="$HOME_DIR" CS_STARTUP_MEMORY_MAX_BYTES=not-a-number "$BIN" 2>/dev/null)
assert_contains "$out" 'against a 8192-byte budget' "a malformed budget falls back to the default"
pass "a malformed budget falls back to the default rather than silently disabling the check"

# --- section ordering: preamble pinned, fleet state before curated memory ------
# grep -n positions of the real emitted headers; every header regex is anchored
# so the closing reminder's mention of the contract never matches.
section_line() { printf '%s\n' "$1" | grep -n "^$2\$" | head -1 | cut -d: -f1; }

HOME_DIR=$(fresh_home ordering)
printf 'window=x:w1\nkind=ship\n' > "$HOME_DIR/state/task-a.meta"
printf 'working: on it\n' > "$HOME_DIR/state/task-a.status"
printf 'Boss memory that may be truncated away safely.\n' > "$HOME_DIR/config/boss.md"
out=$(CS_HOME="$HOME_DIR" "$BIN" 2>/dev/null)

lock_line=$(section_line "$out" 'LOCK')
boot_line=$(section_line "$out" 'BOOTSTRAP')
wake_line=$(section_line "$out" 'WAKE QUEUE')
supervision_line=$(section_line "$out" 'SUPERVISION (foreground checkpoint)')
read_once_line=$(section_line "$out" 'READ-ONCE CONTRACT')
fleet_line=$(section_line "$out" 'FLEET STATE')
context_line=$(section_line "$out" 'CONTEXT')
next_line=$(section_line "$out" 'NEXT STEP')
inventory_line=$(section_line "$out" '--- task-a ---')
backlog_line=$(section_line "$out" 'config/backlog.md')

if [ -z "$lock_line" ] || [ -z "$boot_line" ] || [ -z "$wake_line" ] \
  || [ -z "$supervision_line" ] \
  || [ -z "$read_once_line" ] || [ -z "$fleet_line" ] || [ -z "$context_line" ] \
  || [ -z "$next_line" ] || [ -z "$inventory_line" ] || [ -z "$backlog_line" ]; then
  fail "one or more section headers missing from digest: $out"
fi

# The safety preamble's order is unchanged: mutation authority, then
# diagnostics, then this turn's work queue, before anything bulky is read.
[ "$lock_line" -lt "$boot_line" ] || fail "LOCK did not precede BOOTSTRAP"
[ "$boot_line" -lt "$wake_line" ] || fail "BOOTSTRAP did not precede WAKE QUEUE"
[ "$wake_line" -lt "$supervision_line" ] || fail "WAKE QUEUE did not precede SUPERVISION"
[ "$supervision_line" -lt "$read_once_line" ] || fail "SUPERVISION did not precede the read-once contract"

[ "$read_once_line" -lt "$fleet_line" ] || fail "the read-once contract did not precede FLEET STATE"
[ "$fleet_line" -lt "$context_line" ] || fail "FLEET STATE did not precede CONTEXT"
[ "$context_line" -lt "$next_line" ] || fail "CONTEXT did not precede NEXT STEP"

# The live-task inventory - the record recovery actually depends on - must sit
# ahead of the curated memory a truncated tail is allowed to take, and ahead of
# the backlog listing inside FLEET STATE too: the backlog scales with fleet
# size, so anything printed after it is what a deep fleet pushes off the end.
[ "$inventory_line" -lt "$context_line" ] \
  || fail "the live-task inventory was buried behind the curated memory files"
[ "$fleet_line" -lt "$inventory_line" ] \
  || fail "the live-task inventory printed outside the FLEET STATE section"
[ "$inventory_line" -lt "$backlog_line" ] \
  || fail "the backlog listing was printed ahead of the live-task inventory"
assert_contains "$out" 'Boss memory that may be truncated away safely.' \
  "the ordering fixture did not actually print a memory file"
pass "digest sections are ordered safety-preamble first, live fleet state before curated memory"

HOME_DIR=$(fresh_home ordering-migration)
printf 'Legacy project registry.\n' > "$HOME_DIR/data/projects.md"
# The migration runs only in the session that holds the lock, and the lock is
# granted by walking the process ancestry for a harness. That ancestry is
# environment-dependent - a developer shell under Claude Code has one, a CI
# runner does not - so this fixture widens the harness pattern to the test's own
# shell. Without it the case silently degrades to the read-only path, where no
# LAYOUT MIGRATION section exists to order.
migration_out=$(CS_LOCK_HARNESS_RE='bash|zsh|codex|claude' CS_HOME="$HOME_DIR" "$BIN" 2>/dev/null)

migration_lock_line=$(section_line "$migration_out" 'LOCK')
migration_line=$(section_line "$migration_out" 'LAYOUT MIGRATION')
migration_boot_line=$(section_line "$migration_out" 'BOOTSTRAP')
if [ -z "$migration_lock_line" ] || [ -z "$migration_line" ] || [ -z "$migration_boot_line" ]; then
  fail "the conditional layout-migration fixture did not emit the full opening preamble: $migration_out"
fi
[ "$migration_lock_line" -lt "$migration_line" ] || fail "LOCK did not precede LAYOUT MIGRATION"
[ "$migration_line" -lt "$migration_boot_line" ] || fail "LAYOUT MIGRATION did not precede BOOTSTRAP"
assert_contains "$migration_out" \
  "cs-migrate-config: moved $HOME_DIR/data/projects.md -> $HOME_DIR/config/projects.md" \
  "the ordering fixture did not exercise a real layout migration"
pass "conditional layout migration stays pinned between lock and bootstrap"

# --- the read-once contract is stated once, ahead of its subject ---------------
# It has to survive tail truncation and stay honest once it precedes the
# sections it governs, so it carries the never-emitted-stage escape itself.
assert_contains "$out" 'Do NOT re-read any of them after reading this digest' \
  "the read-once contract lost its core instruction"
assert_contains "$out" 'reports a stage as never emitted' \
  "the read-once contract does not void itself for a stage that never ran"
assert_contains "$out" 'The READ-ONCE CONTRACT' \
  "the closing reminder does not point back at the contract"
contract_count=$(printf '%s\n' "$out" | grep -c 'Do NOT re-read any of them')
[ "$contract_count" -eq 1 ] \
  || fail "the read-once contract is stated $contract_count times instead of once"
pass "the read-once contract is stated once, ahead of the sources it governs"

# --- status-tail per-line cap ---------------------------------------------------
# A soldier writes its own status lines, so nothing upstream bounds their
# length. The tail is a wake-EVENT view whose full log path is printed beside
# it, so a long line is cut, marked, and left recoverable rather than allowed
# to scale the digest with fleet load.
HOME_DIR=$(fresh_home line-cap)
lede='needs-decision: [key=cap] pick the rendering strategy'
unicode_exact=$(awk 'BEGIN { while (i++ < 220) printf "é" }')
printf 'window=x:w1\nkind=ship\n' > "$HOME_DIR/state/task-cap.meta"
{
  printf '%s' "$lede"
  awk 'BEGIN { while (i++ < 400) printf "€" }'
  printf '\n'
  printf '%s\n' "$unicode_exact"
  printf 'working: short line kept whole\n'
} > "$HOME_DIR/state/task-cap.status"

out=$(LC_ALL=C CS_HOME="$HOME_DIR" "$BIN" 2>/dev/null)

assert_contains "$out" "$lede" "the cap discarded the lede that carries the state word and decision key"
assert_contains "$out" ' [truncated]' "an over-long status line was not marked as truncated"
assert_contains "$out" "$unicode_exact" "the inherited C locale truncated a 220-character UTF-8 line"
assert_contains "$out" 'working: short line kept whole' "the cap mangled a status line already under it"
assert_contains "$out" 'each capped at 220 characters' "the status tail header does not disclose its per-line cap"
assert_contains "$out" "$HOME_DIR/state/task-cap.status" "a capped tail dropped the full log path that recovers the rest"

# Nothing the tail emits may exceed the cap, and the padded line really was
# long enough to exercise it.
tail_section=$(printf '%s\n' "$out" | awk '/^status tail \(/ { flag = 1; next } flag && /^$/ { flag = 0 } flag')
longest=$(printf '%s\n' "$tail_section" | python3 -c \
  'import sys; lines = sys.stdin.buffer.read().decode("utf-8").splitlines(); print(max(map(len, lines), default=0))' \
  2>/dev/null) || fail "a capped status tail contained invalid UTF-8"
[ "$longest" -le 220 ] || fail "a status tail line ran $longest characters past the 220-character cap"
capped=$(printf '%s\n' "$tail_section" | grep -c ' \[truncated\]$')
[ "$capped" -eq 1 ] || fail "expected exactly one truncated tail line, got $capped: $tail_section"
pass "status tail lines are capped with a truncation marker while the full log stays reachable"

HOME_DIR=$(fresh_home malformed-line-cap)
printf 'window=x:w1\nkind=ship\n' > "$HOME_DIR/state/task-malformed.meta"
{
  printf 'malformed: '
  i=0
  while [ "$i" -lt 221 ]; do
    printf '\200'
    i=$((i + 1))
  done
  printf '\n'
} > "$HOME_DIR/state/task-malformed.status"
malformed_out="$TMP/malformed-line-cap.out"
LC_ALL=C CS_HOME="$HOME_DIR" "$BIN" > "$malformed_out" 2>/dev/null
python3 - "$malformed_out" <<'PY' \
  || fail "malformed UTF-8 bytes bypassed the shared line cap"
import sys

lines = open(sys.argv[1], "rb").read().splitlines()
line = next(line for line in lines if line.startswith(b"malformed: "))
assert len(line) == 220, len(line)
assert line.endswith(b" [truncated]"), line[-32:]
assert line.count(b"\x80") == 197, line.count(b"\x80")
PY
pass "malformed UTF-8 bytes each consume one cap position"

# --- backlog composition fixtures ----------------------------------------------
# A backlog whose Done section, held row, blocked row, and plain queued rows can
# each be told apart in the rendered digest. DONE-ROW-LINE and the *-BODY-LINE
# markers exist so a leak is unmistakable.
write_long_body_backlog() {
  local path=$1 i=1
  cat > "$path" <<'EOF'
# Backlog

## In flight
- [ ] compact-startup - Compact startup digest (repo: consigliere) (kind: ship)
  OVERSIZED-BODY-LINE this is a long multiline note that must never print.

## Queued
- [ ] blocked-followup - Follow compact startup blocked-by: compact-startup - waits for implementation (repo: consigliere) (kind: scout)
  QUEUED-BODY-LINE this is another long multiline note.
- [ ] held-queued - Held queued work (repo: consigliere) (kind: ship) (hold: boss choice pending) (hold-kind: captain)
EOF
  while [ "$i" -le 25 ]; do
    printf -- '- [ ] plain-%s - Plain queued item %s (repo: consigliere) (kind: ship)\n' "$i" "$i" >> "$path"
    i=$((i + 1))
  done
  cat >> "$path" <<'EOF'
- [ ] publish-obligation - Publish required follow-up (repo: consigliere) (kind: public-followup)

## Done
- [x] landed-earlier - DONE-ROW-LINE already landed and torn down (repo: consigliere) (kind: ship)
EOF
}

# make_fake_tasks_axi <fakebin>: a tasks-axi boundary that answers the four
# group filters the startup listing composes (in-flight, held, blocked queued,
# and the dispatchable ready set) and REFUSES anything the recovery listing must
# never ask for: a body field, an unfiltered whole-backlog listing, or done
# rows. CS_FAKE_TASKS_AXI_READY sizes the ready set and CS_FAKE_TASKS_AXI_ACTIVE
# sizes each actionable group, so either bound can be driven past its limit.
make_fake_tasks_axi() {
  local fakebin=$1
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
log=${CS_FAKE_TASKS_AXI_LOG:-}
[ -n "$log" ] && printf '%s\n' "$*" >> "$log"
ready_count=${CS_FAKE_TASKS_AXI_READY:-2}
active_count=${CS_FAKE_TASKS_AXI_ACTIVE:-1}
followup_count=${CS_FAKE_TASKS_AXI_FOLLOWUPS:-1}
pad_rows() {  # <prefix> <state> - the filler rows after the canonical first one
  i=2
  while [ "$i" -le "$active_count" ]; do
    printf '  %s-%s,%s,ship,consigliere,Filler %s item %s,none,"-","-"\n' \
      "$1" "$i" "$2" "$1" "$i"
    i=$((i + 1))
  done
}
require_file() {
  case "$*" in *'--file '*) return 0 ;; esac
  printf '%s\n' 'missing explicit backlog file' >&2
  exit 9
}
task_header() {
  printf 'count: %s\n' "$1"
  printf 'tasks[%s]{id,state,kind,repo,title,blocked_by,hold_kind,hold_reason}:\n' "$1"
}
list_help() {
  printf 'help[1]:\n'
  printf '%s\n' '  - Run `tasks-axi show <id> --full` for full notes on a task'
}
case "${1:-}" in
  --version|-v|-V)
    printf '%s\n' '0.2.4'
    exit 0
    ;;
  ready)
    require_file "$@"
    printf 'count: %s\n' "$ready_count"
    printf 'ready[%s]{id,state,kind,repo,title}:\n' "$ready_count"
    i=1
    while [ "$i" -le "$ready_count" ]; do
      printf '  ready-%s,queued,ship,consigliere,Ready item %s\n' "$i" "$i"
      i=$((i + 1))
    done
    printf 'ready_public_followups: 0 delivery-ready obligations\n'
    printf 'help[1]:\n'
    printf '%s\n' '  - Run `tasks-axi start <id>` to dispatch one of these'
    exit 0
    ;;
  list)
    case "$*" in
      *'--fields '*'body'*|*'--fields='*'body'*)
        printf '%s\n' 'compact listing must not request body' >&2
        exit 9
        ;;
    esac
    require_file "$@"
    case "$*" in
      *'--state done'*)
        printf '%s\n' 'startup recovery must never list done rows' >&2
        exit 9
        ;;
      *'--state in_flight'*)
        task_header "$active_count"
        printf '%s\n' '  compact-startup,in_flight,ship,consigliere,Compact startup digest,none,captain,boss choice pending'
        pad_rows in-flight in_flight
        ;;
      *'--state held'*)
        task_header "$active_count"
        printf '%s\n' '  held-queued,queued,ship,consigliere,Held queued work,none,captain,boss choice pending'
        pad_rows held queued
        ;;
      *'--kind public-followup'*)
        # An obligation is only actionable with its delivery_state, so the real
        # boundary is asked for it; refuse a listing that leaves it out.
        case "$*" in
          *'--fields '*'delivery_state'*) : ;;
          *)
            printf '%s\n' 'obligation listing must request delivery_state' >&2
            exit 9
            ;;
        esac
        printf 'count: %s\n' "$followup_count"
        printf 'tasks[%s]{id,state,kind,repo,title,delivery_state,blocked_by,hold_kind,hold_reason}:\n' "$followup_count"
        i=1
        while [ "$i" -le "$followup_count" ]; do
          printf '  publish-obligation-%s,queued,public-followup,consigliere,Publish required follow-up %s,intent,none,"-","-"\n' "$i" "$i"
          i=$((i + 1))
        done
        ;;
      *'--state queued'*'--blocked'*)
        task_header "$active_count"
        printf '%s\n' '  blocked-followup,queued,scout,consigliere,Follow compact startup,compact-startup,"-","-"'
        pad_rows blocked queued
        ;;
      *)
        printf '%s\n' 'startup recovery must not request an unfiltered whole-backlog listing' >&2
        exit 9
        ;;
    esac
    list_help
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
}

# --- backlog: tasks-axi composition drops done rows, keeps actionable rows -----
HOME_DIR=$(fresh_home axi-compose)
FAKEBIN=$(cs_fakebin "$TMP/axi-compose-tools")
make_fake_tasks_axi "$FAKEBIN"
write_long_body_backlog "$HOME_DIR/config/backlog.md"
AXI_LOG="$TMP/axi-compose.log"
: > "$AXI_LOG"

out=$(CS_HOME="$HOME_DIR" CS_FAKE_TASKS_AXI_LOG="$AXI_LOG" CS_FAKE_TASKS_AXI_READY=3 \
  PATH="$FAKEBIN:$PATH" "$BIN" 2>/dev/null)

assert_contains "$out" 'compact backlog listing (tasks-axi; done rows omitted; in-flight, held, and blocked rows shown in full up to 40 per group; queued public-followup obligations always shown in full; ready queued bounded to 20; task bodies omitted)' \
  "tasks-axi backend did not render the composed recovery listing"
assert_contains "$out" 'compact-startup,in_flight,ship,consigliere,Compact startup digest,none,captain,boss choice pending' \
  "tasks-axi listing omitted in-flight identity, state, or hold metadata"
assert_contains "$out" 'held-queued,queued,ship,consigliere,Held queued work,none,captain,boss choice pending' \
  "tasks-axi listing omitted a held row or its hold metadata"
assert_contains "$out" 'blocked-followup,queued,scout,consigliere,Follow compact startup,compact-startup,"-","-"' \
  "tasks-axi listing omitted blocked-by metadata"
assert_contains "$out" 'ready-3,queued,ship,consigliere,Ready item 3' \
  "tasks-axi listing omitted a dispatchable queued row inside the bound"
assert_not_contains "$out" 'DONE-ROW-LINE' "tasks-axi digest listed a done row at startup"
assert_contains "$out" 'ready_public_followups: 0 delivery-ready obligations' \
  "the composed listing dropped a real signal from the dispatchable set"
# An obligation still in `intent` reaches ready_public_followups only once it is
# delivery-ready, so its own group is the only thing that can surface it.
assert_contains "$out" 'publish-obligation-1,queued,public-followup,consigliere,Publish required follow-up 1,intent,none,"-","-"' \
  "the composed listing dropped a queued public-followup obligation"
# One section pointer, not one repeated help block per composed group.
assert_not_contains "$out" 'help[1]:' \
  "the composed listing repeated tasks-axi's per-group help block"
assert_contains "$out" 'Full task bodies remain available on demand: tasks-axi show <id> --full' \
  "the composed listing omitted the full-body lookup pointer"
# A group inside its bound reports what it showed and claims no remainder.
assert_contains "$out" '(shown 1 of 1 in-flight item(s))' \
  "an actionable group did not account for the rows it showed"
assert_not_contains "$out" 'more in-flight - tasks-axi list' \
  "a complete in-flight group claimed an omitted remainder"

# The fake refuses a body field, an unfiltered listing, and a done listing, so
# a clean render already proves those were never asked for; pin the group
# filters the listing is built from.
assert_grep '--state in_flight --fields blocked_by,hold_kind,hold_reason' "$AXI_LOG" \
  "session start did not ask tasks-axi for the in-flight group"
assert_grep '--state held --fields blocked_by,hold_kind,hold_reason' "$AXI_LOG" \
  "session start did not ask tasks-axi for the held group"
assert_grep '--state queued --blocked --fields blocked_by,hold_kind,hold_reason' "$AXI_LOG" \
  "session start did not ask tasks-axi for the blocked queued group"
assert_grep '--state queued --kind public-followup --fields delivery_state,blocked_by,hold_kind,hold_reason' "$AXI_LOG" \
  "session start did not ask tasks-axi for the queued obligations group"
assert_grep "ready --file $HOME_DIR/config/backlog.md" "$AXI_LOG" \
  "session start did not ask tasks-axi for the dispatchable queued set"
pass "tasks-axi backlog rendering drops done rows and keeps every in-flight, held, and blocked row"

# --- backlog: the queued bound cuts only dispatchable rows and discloses it ----
HOME_DIR=$(fresh_home axi-bound)
FAKEBIN=$(cs_fakebin "$TMP/axi-bound-tools")
make_fake_tasks_axi "$FAKEBIN"
write_long_body_backlog "$HOME_DIR/config/backlog.md"

out=$(CS_HOME="$HOME_DIR" CS_FAKE_TASKS_AXI_READY=7 CS_SESSION_START_QUEUED_LIMIT=3 \
  PATH="$FAKEBIN:$PATH" "$BIN" 2>/dev/null)

assert_contains "$out" 'ready-3,queued,ship,consigliere,Ready item 3' \
  "the queued bound dropped a row inside its own limit"
assert_not_contains "$out" 'ready-4,queued' "the queued bound did not actually bound the ready listing"
assert_contains "$out" '(shown 3 of 7 ready queued item(s))' \
  "the bounded queued listing did not report what it showed"
assert_contains "$out" "(4 more ready queued - tasks-axi ready --file $HOME_DIR/config/backlog.md)" \
  "the bounded queued listing did not disclose an exact remainder and how to see it"

# The bound is for dispatchable work only: held and blocked rows stay whole.
assert_contains "$out" 'held-queued,queued,ship,consigliere,Held queued work,none,captain,boss choice pending' \
  "the queued bound swallowed a held row"
assert_contains "$out" 'blocked-followup,queued,scout,consigliere,Follow compact startup,compact-startup,"-","-"' \
  "the queued bound swallowed a blocked row"
assert_contains "$out" 'compact-startup,in_flight,ship,consigliere,Compact startup digest,none,captain,boss choice pending' \
  "the queued bound swallowed an in-flight row"
pass "the startup backlog bound cuts only dispatchable queued rows and discloses the remainder exactly"

# --- backlog: the actionable groups are bounded too, and disclose the cut ------
# The backlog listing shares the digest with the live-task inventory above it,
# so a pathological fleet may not spend the whole payload on actionable rows
# either. Each group keeps its rows whole up to the bound and then says exactly
# how many it withheld and which command prints them.
HOME_DIR=$(fresh_home axi-active-bound)
FAKEBIN=$(cs_fakebin "$TMP/axi-active-bound-tools")
make_fake_tasks_axi "$FAKEBIN"
write_long_body_backlog "$HOME_DIR/config/backlog.md"
FIELDS='blocked_by,hold_kind,hold_reason'

out=$(CS_HOME="$HOME_DIR" CS_FAKE_TASKS_AXI_ACTIVE=5 CS_SESSION_START_ACTIVE_LIMIT=2 \
  PATH="$FAKEBIN:$PATH" "$BIN" 2>/dev/null)

assert_contains "$out" 'compact-startup,in_flight,ship,consigliere,Compact startup digest,none,captain,boss choice pending' \
  "the actionable bound dropped a row inside its own limit"
assert_contains "$out" 'in-flight-2,in_flight,ship,consigliere,Filler in-flight item 2' \
  "the actionable bound dropped the second row inside its own limit"
assert_not_contains "$out" 'in-flight-3,in_flight' "the in-flight group was not actually bounded"
assert_not_contains "$out" 'held-3,queued' "the held group was not actually bounded"
assert_not_contains "$out" 'blocked-3,queued' "the blocked queued group was not actually bounded"

assert_contains "$out" '(shown 2 of 5 in-flight item(s))' \
  "the bounded in-flight group did not report what it showed"
assert_contains "$out" "(3 more in-flight - tasks-axi list --file $HOME_DIR/config/backlog.md --state in_flight --fields $FIELDS)" \
  "the bounded in-flight group did not disclose an exact remainder and how to see it"
assert_contains "$out" '(shown 2 of 5 held item(s))' \
  "the bounded held group did not report what it showed"
assert_contains "$out" "(3 more held - tasks-axi list --file $HOME_DIR/config/backlog.md --state held --fields $FIELDS)" \
  "the bounded held group did not disclose an exact remainder and how to see it"
assert_contains "$out" '(shown 2 of 5 blocked queued item(s))' \
  "the bounded blocked queued group did not report what it showed"
assert_contains "$out" "(3 more blocked queued - tasks-axi list --file $HOME_DIR/config/backlog.md --state queued --blocked --fields $FIELDS)" \
  "the bounded blocked queued group did not disclose an exact remainder and how to see it"
pass "tasks-axi actionable groups are bounded per group with an exact disclosed remainder"

# --- backlog: obligations survive every bound on the tasks-axi path too ---------
# A queued public-followup row is a delivery the boss is already owed, and it
# reaches ready_public_followups only once it is delivery-ready. With both
# bounds squeezed to 1, the digest must still print every obligation while it
# visibly cuts the groups that are allowed to be cut.
HOME_DIR=$(fresh_home axi-obligations)
FAKEBIN=$(cs_fakebin "$TMP/axi-obligations-tools")
make_fake_tasks_axi "$FAKEBIN"
write_long_body_backlog "$HOME_DIR/config/backlog.md"

out=$(CS_HOME="$HOME_DIR" CS_FAKE_TASKS_AXI_FOLLOWUPS=5 CS_FAKE_TASKS_AXI_ACTIVE=3 \
  CS_FAKE_TASKS_AXI_READY=3 CS_SESSION_START_ACTIVE_LIMIT=1 CS_SESSION_START_QUEUED_LIMIT=1 \
  PATH="$FAKEBIN:$PATH" "$BIN" 2>/dev/null)

i=1
while [ "$i" -le 5 ]; do
  assert_contains "$out" "publish-obligation-$i,queued,public-followup,consigliere,Publish required follow-up $i,intent,none," \
    "an obligation was withheld by a bound that must not reach it"
  i=$((i + 1))
done
assert_not_contains "$out" 'more public-followup' \
  "the digest disclosed a withheld obligation instead of printing it"
# The same run really is bounding what it is allowed to bound.
assert_not_contains "$out" 'in-flight-2,in_flight' "the in-flight bound stopped applying"
assert_not_contains "$out" 'ready-2,queued' "the ready queued bound stopped applying"
pass "queued public-followup obligations are exempt from every bound on the tasks-axi path"

# --- backlog: manual backend composition ----------------------------------------
HOME_DIR=$(fresh_home manual-compose)
printf 'manual\n' > "$HOME_DIR/config/backlog-backend.conf"
write_long_body_backlog "$HOME_DIR/config/backlog.md"

out=$(CS_HOME="$HOME_DIR" CS_SESSION_START_QUEUED_LIMIT=4 "$BIN" 2>/dev/null)

assert_contains "$out" 'compact backlog listing (manual backend; done rows omitted; in-flight, held, and blocked title lines bounded to 40 per group; public-followup rows never bounded; other queued bounded to 4; indented task bodies omitted)' \
  "manual backend did not use the composed title-line rendering"
assert_contains "$out" '## In flight' "manual rendering omitted the in-flight section heading"
assert_contains "$out" '- [ ] compact-startup - Compact startup digest' \
  "manual rendering omitted an in-flight title line"
assert_contains "$out" '(hold: boss choice pending)' "manual rendering omitted hold metadata"
assert_contains "$out" 'blocked-by: compact-startup - waits for implementation' \
  "manual rendering omitted blocker metadata"
assert_contains "$out" '- [ ] held-queued - Held queued work' \
  "manual rendering dropped a held queued title line"
assert_contains "$out" '- [ ] publish-obligation - Publish required follow-up (repo: consigliere) (kind: public-followup)' \
  "manual rendering bounded away a public-followup obligation"
assert_not_contains "$out" 'OVERSIZED-BODY-LINE' "manual digest leaked an in-flight task body"
assert_not_contains "$out" 'QUEUED-BODY-LINE' "manual digest leaked a queued task body"
assert_not_contains "$out" 'DONE-ROW-LINE' "manual digest listed a done row at startup"
assert_not_contains "$out" '## Done' "manual digest printed the done heading it never fills"
assert_contains "$out" '- [ ] plain-4 - Plain queued item 4' \
  "manual rendering dropped a queued title line inside its bound"
assert_not_contains "$out" '- [ ] plain-5 - Plain queued item 5' \
  "manual rendering did not bound its plain queued listing"
assert_contains "$out" '(shown 1 of 1 in-flight, 2 of 2 held or blocked queued, all 1 public-followup queued, 4 of 25 other queued title line(s); 1 done row(s) omitted)' \
  "manual rendering did not report its bound accounting"
assert_contains "$out" '(21 more queued - raise CS_SESSION_START_QUEUED_LIMIT, or read the Queued section of config/backlog.md for those rows)' \
  "manual rendering did not disclose an exact queued remainder"
assert_not_contains "$out" 'more in-flight - raise CS_SESSION_START_ACTIVE_LIMIT' \
  "manual rendering claimed a remainder for a complete in-flight group"
assert_contains "$out" 'or config/backlog.md' "manual digest omitted the config/backlog.md full-body pointer"
pass "manual backlog rendering keeps held, blocked, and public-followup rows while bounding the rest"

# --- backlog: the manual actionable groups are bounded, obligations are not ----
# The obligation sits AFTER enough held and blocked rows to exhaust the bound,
# which is the shape that hides it: a delivery the boss is already owed must
# still print in full while lower-priority dispatchable work does.
write_active_bound_backlog() {
  local path=$1 i=1
  printf '# Backlog\n\n## In flight\n' > "$path"
  while [ "$i" -le 3 ]; do
    printf -- '- [ ] flight-%s - In flight item %s (repo: consigliere) (kind: ship)\n' "$i" "$i" >> "$path"
    i=$((i + 1))
  done
  cat >> "$path" <<'EOF'

## Queued
- [ ] held-one - First held item (repo: consigliere) (kind: ship) (hold: boss choice pending)
- [ ] held-two - Second held item (repo: consigliere) (kind: ship) (hold: boss choice pending)
- [ ] blocked-one - Blocked item blocked-by: flight-1 (repo: consigliere) (kind: scout)
- [ ] publish-obligation - Publish required follow-up (repo: consigliere) (kind: public-followup)
- [ ] plain-one - Plain queued item (repo: consigliere) (kind: ship)
EOF
}

HOME_DIR=$(fresh_home manual-active-bound)
printf 'manual\n' > "$HOME_DIR/config/backlog-backend.conf"
write_active_bound_backlog "$HOME_DIR/config/backlog.md"

out=$(CS_HOME="$HOME_DIR" CS_SESSION_START_ACTIVE_LIMIT=2 "$BIN" 2>/dev/null)

assert_contains "$out" '- [ ] flight-2 - In flight item 2' \
  "the manual actionable bound dropped a row inside its own limit"
assert_not_contains "$out" '- [ ] flight-3 - In flight item 3' \
  "the manual in-flight group was not actually bounded"
assert_contains "$out" '- [ ] held-two - Second held item' \
  "the manual actionable bound dropped a held row inside its own limit"
assert_not_contains "$out" '- [ ] blocked-one - Blocked item' \
  "the manual held and blocked group was not actually bounded"
assert_contains "$out" '- [ ] publish-obligation - Publish required follow-up (repo: consigliere) (kind: public-followup)' \
  "an exhausted actionable bound hid a delivery obligation"
assert_contains "$out" '- [ ] plain-one - Plain queued item' \
  "the manual rendering hid an obligation while still printing plain queued work"
assert_contains "$out" '(shown 2 of 3 in-flight, 2 of 3 held or blocked queued, all 1 public-followup queued, 1 of 1 other queued title line(s); 0 done row(s) omitted)' \
  "manual rendering did not account for its bounded actionable groups"
assert_contains "$out" '(1 more in-flight - raise CS_SESSION_START_ACTIVE_LIMIT, or read the In flight section of config/backlog.md for those rows)' \
  "manual rendering did not disclose the in-flight remainder it withheld"
assert_contains "$out" '(1 more held or blocked queued - raise CS_SESSION_START_ACTIVE_LIMIT, or read the Queued section of config/backlog.md for those rows)' \
  "manual rendering did not disclose the actionable queued remainder it withheld"
assert_not_contains "$out" 'more public-followup' \
  "the digest claimed it withheld a delivery obligation"
pass "manual actionable groups are bounded while public-followup obligations stay unbounded"

# --- the read-once contract sanctions every disclosed remainder ----------------
# The backlog section tells the agent how to recover a withheld row; the
# contract two sections earlier forbids bulk-reading the same file. They have to
# agree, or an agent obeying the contract literally cannot recover the rows
# AGENTS.md sections 7 and 10 make most actionable.
assert_contains "$out" 'the backlog listing disclosed omitted rows in any of its groups - in-flight,' \
  "the read-once contract still sanctions only omitted queued items"
assert_contains "$out" 'targeted follow-up that disclosure names' \
  "the read-once contract did not point at the targeted follow-up over a bulk read"
assert_not_contains "$out" 'read config/backlog.md for the rest' \
  "a remainder line still advised the bulk read the contract forbids"
pass "the read-once contract covers every disclosed backlog remainder without sanctioning a bulk read"

# --- bootstrap's fatal BASH_FLOOR blocker refuses the whole session -----------
# Every ordinary bootstrap problem stays a soft digest line; the bash floor is
# the one session-fatal blocker (bin/cs-session-start.sh states why beside the
# rc check). Driven end to end through a symlink-farm bin whose cs-deps-lib.sh
# declares a floor no real bash meets, so the real bootstrap refusal and the
# real session-start rc handling both fire.
FLOORBIN="$TMP/floor-bin"
mkdir -p "$FLOORBIN"
for f in "$ROOT"/bin/*; do ln -s "$f" "$FLOORBIN/$(basename "$f")"; done
rm "$FLOORBIN/cs-deps-lib.sh"
sed 's/^BASH_FLOOR_MAJOR=.*/BASH_FLOOR_MAJOR=99/; s/^BASH_FLOOR_MINOR=.*/BASH_FLOOR_MINOR=9/' \
  "$ROOT/bin/cs-deps-lib.sh" > "$FLOORBIN/cs-deps-lib.sh"
HOME_DIR=$(fresh_home floor)
rc=0
out=$(CS_HOME="$HOME_DIR" "$FLOORBIN/cs-session-start.sh" 2>/dev/null) || rc=$?
[ "$rc" -eq 78 ] || fail "a fatal BASH_FLOOR blocker must refuse the session with exit 78, got $rc"
assert_contains "$out" 'BASH_FLOOR:' "the digest shows the blocker line"
assert_contains "$out" 'SESSION START REFUSED' "the refusal is stated in the digest"
assert_not_contains "$out" 'WAKE QUEUE' "no stage after the refusal may run"
pass "session start refuses on the bash-floor blocker instead of proceeding"

pass "cs-session-start digest composition"
