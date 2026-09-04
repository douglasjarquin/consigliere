#!/usr/bin/env bash
# Behavior (portable): the session-open router bin/cs-sessionstart-run.sh, the
# session-start runtime bound, and the --reemit contract.
#
# The router is the single owner of what a session-open source means, so these
# cases prove routing by the digest that actually appears, never by inspecting
# the router's source:
#   - startup and an unrecognized or unreadable source run the FULL digest
#   - clear/compact re-emit only after this lock owner recorded a completed
#     full startup, and run the full digest otherwise
#   - resume/reload/fork print one typed nudge line, and stay silent when this
#     session already holds the lock
#   - a no-mistakes gate agent and an unmarked linked task worktree are silent
# The runtime bound cases drive a REAL hung subprocess and assert the outcome
# the session-open hook depends on: whatever the digest already emitted
# survives, the truncation banner names the stalled stage and every stage that
# never ran, no completion proof is recorded, and the command still exits 0 so
# the session can open.
# A bound that cannot be established at all is proven to report itself as a
# digest that NEVER RAN rather than as a stall, because naming a stalled stage
# for a command that never started tells the reader the opposite of the truth.
# The --reemit cases prove the two things a re-emit must NOT skip (lock
# re-verification and the wake-queue drain) and the two things it must skip
# (bootstrap's mutating sweeps, with repair ownership kept via
# CS_BOOTSTRAP_LOCKED).
# The hook cases execute the exact tracked hook command strings twice: from a
# checkout that is not a consigliere home, where they must be silent and exit
# 0, and from a checkout that is one, where they must produce the digest.
set -u

# Run the whole suite beneath one long-lived harness-named fixture shell,
# matching the real lifecycle in which the startup hook and later clear/compact
# hooks share one harness ancestor. cs-lock.sh's ancestry walk then resolves
# every lock to this stable fixture pid instead of a transient script shell,
# and the router's own ancestry check sees the same owner.
if [ "${CS_SESSIONSTART_TEST_HARNESS:-0}" != 1 ]; then
  HARNESS_FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/cs-sessionstart-harness.XXXXXX") || exit 1
  ln -s /bin/bash "$HARNESS_FIXTURE/codex" || exit 1
  # shellcheck disable=SC2016 # Expand in the fixture shell, not this parent.
  CS_SESSIONSTART_TEST_HARNESS=1 "$HARNESS_FIXTURE/codex" \
    -c '"$@"; rc=$?; :; exit "$rc"' _ "$0" "$@"
  HARNESS_STATUS=$?
  rm -rf "$HARNESS_FIXTURE"
  exit "$HARNESS_STATUS"
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset NO_MISTAKES_GATE
unset CS_TASK_ID
unset CS_ROOT_OVERRIDE CS_HOME CS_STATE_OVERRIDE CS_DATA_OVERRIDE CS_CONFIG_OVERRIDE CS_HOST_OVERRIDE

TMP=$(cs_test_tmproot cs-sessionstart-run)
RUN="$ROOT/bin/cs-sessionstart-run.sh"
SESSION_START="$ROOT/bin/cs-session-start.sh"
BASE_PATH=${CS_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
BASH_BIN_DIR=$(dirname "$(command -v bash)")
FIXTURE_PID=$PPID
cs_git_identity

# new_world <name> [<root-branch>]: a consigliere-primary-shaped root (a plain
# git checkout carrying AGENTS.md and bin/) plus an isolated CS_HOME. Echoes
# "<root>|<home>".
new_world() {
  local name=$1 branch=${2:-main} w root home
  w="$TMP/$name"
  root="$w/root"
  home="$w/home"
  mkdir -p "$root/bin" "$home/state" "$home/data" "$home/config"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  if [ "$branch" != main ]; then
    git -C "$root" checkout -q -b "$branch"
  fi
  : > "$root/AGENTS.md"
  printf '%s|%s\n' "$root" "$home"
}

# run_router <root> <home> <payload> [args...]: pipe a hook payload into the
# real router against the given world.
run_router() {
  local root=$1 home=$2 payload=$3
  shift 3
  (cd "$root" && printf '%s' "$payload" | CS_ROOT_OVERRIDE="$root" CS_HOME="$home" "$RUN" "$@")
}

run_session_start() {
  local root=$1 home=$2
  shift 2
  (cd "$root" && CS_ROOT_OVERRIDE="$root" CS_HOME="$home" "$SESSION_START" "$@")
}

# own_lock <home>: record the long-lived fixture shell as this session's lock
# holder, exactly what a real startup leaves behind.
own_lock() {
  printf '%s\n' "$FIXTURE_PID" > "$1/state/.lock"
}

# --- source routing: startup runs the full digest ------------------------------
IFS='|' read -r ROOT_DIR HOME_DIR <<<"$(new_world startup)"
out=$(run_router "$ROOT_DIR" "$HOME_DIR" '{"source":"startup"}')
assert_contains "$out" "SESSION START - $HOME_DIR" "startup did not run the full digest"
assert_not_contains "$out" 'CONTEXT RE-EMIT' "startup must never re-emit"
pass "source=startup runs the full digest"

# --- source routing: unrecognized and unreadable sources run the full digest ---
IFS='|' read -r ROOT_DIR HOME_DIR <<<"$(new_world garbage)"
out=$(run_router "$ROOT_DIR" "$HOME_DIR" '{"source":"whatever"}')
assert_contains "$out" "SESSION START - $HOME_DIR" "an unrecognized source did not run the full digest"
out=$(run_router "$ROOT_DIR" "$HOME_DIR" 'not json at all')
assert_contains "$out" "SESSION START - $HOME_DIR" "an unreadable payload did not run the full digest"
pass "unrecognized and unreadable sources fall through to the full digest"

SOLDIER_PRIMARY="$TMP/soldier-primary"
SOLDIER_WORKTREE="$TMP/soldier-worktree"
cs_git_worktree "$SOLDIER_PRIMARY" "$SOLDIER_WORKTREE" cs/soldier
mkdir -p "$SOLDIER_PRIMARY/bin" "$TMP/soldier-home/state" "$TMP/soldier-home/data" \
  "$TMP/soldier-home/config"
: > "$SOLDIER_PRIMARY/AGENTS.md"
SOLDIER_HOME="$TMP/soldier-home"
printf 'lock-sentinel\n' > "$SOLDIER_HOME/state/.lock"
printf 'wake-sentinel\n' > "$SOLDIER_HOME/state/.wake-queue"
printf 'pane-sentinel\n' > "$SOLDIER_HOME/state/.home-pane"
out=$(cd "$SOLDIER_WORKTREE" && printf '%s' '{"source":"startup"}' \
  | CS_ROOT_OVERRIDE="$SOLDIER_PRIMARY" CS_HOME="$SOLDIER_HOME" \
    CS_STATE_OVERRIDE="$SOLDIER_HOME/state" CS_DATA_OVERRIDE="$SOLDIER_HOME/data" \
    CS_TASK_ID=fix-soldier-lock-hijack "$RUN")
[ -z "$out" ] || fail "a soldier session-start hook must be silent, got: $out"
[ "$(cat "$SOLDIER_HOME/state/.lock")" = 'lock-sentinel' ] || \
  fail "a soldier session-start hook overwrote the primary lock"
[ "$(cat "$SOLDIER_HOME/state/.wake-queue")" = 'wake-sentinel' ] || \
  fail "a soldier session-start hook drained the primary wake queue"
[ "$(cat "$SOLDIER_HOME/state/.home-pane")" = 'pane-sentinel' ] || \
  fail "a soldier session-start hook overwrote the primary home pane"
assert_absent "$SOLDIER_HOME/state/.session-start-complete" \
  "a soldier session-start hook recorded completion"
pass "primary-home overrides plus a soldier task id never start the primary session"

printf 'lock-sentinel\n' > "$SOLDIER_HOME/state/.lock"
printf 'wake-sentinel\n' > "$SOLDIER_HOME/state/.wake-queue"
printf 'pane-sentinel\n' > "$SOLDIER_HOME/state/.home-pane"
out=$(cd "$SOLDIER_WORKTREE" && printf '%s' '{"source":"startup"}' \
  | CS_ROOT_OVERRIDE="$SOLDIER_PRIMARY" CS_HOME="$SOLDIER_HOME" \
    CS_STATE_OVERRIDE="$SOLDIER_HOME/state" CS_DATA_OVERRIDE="$SOLDIER_HOME/data" \
    CS_TASK_ID='' "$RUN")
[ -z "$out" ] || fail "a mismatched soldier cwd must be silent, got: $out"
[ "$(cat "$SOLDIER_HOME/state/.lock")" = 'lock-sentinel' ] || \
  fail "a mismatched soldier cwd overwrote the primary lock"
[ "$(cat "$SOLDIER_HOME/state/.wake-queue")" = 'wake-sentinel' ] || \
  fail "a mismatched soldier cwd drained the primary wake queue"
[ "$(cat "$SOLDIER_HOME/state/.home-pane")" = 'pane-sentinel' ] || \
  fail "a mismatched soldier cwd overwrote the primary home pane"
assert_absent "$SOLDIER_HOME/state/.session-start-complete" \
  "a mismatched soldier cwd recorded completion"
pass "primary-home overrides plus a mismatched soldier cwd never start the primary session"

IFS='|' read -r ROOT_DIR HOME_DIR <<<"$(new_world capo)"
printf 'capo-1\n' > "$ROOT_DIR/.cs-capo-home"
out=$(cd "$ROOT_DIR" && printf '%s' '{"source":"startup"}' \
  | CS_ROOT_OVERRIDE="$ROOT_DIR" CS_HOME="$HOME_DIR" \
    CS_TASK_ID=capo-task "$RUN")
assert_contains "$out" "SESSION START - $HOME_DIR" \
  "a marked capo session with a task id did not run its own startup"
assert_contains "$out" 'lock acquired' \
  "a marked capo session with a task id did not acquire its own lock"
pass "a marked capo session retains project-scoped startup with CS_TASK_ID"

# --- source routing: clear without completion proof runs the full digest -------
IFS='|' read -r ROOT_DIR HOME_DIR <<<"$(new_world clear-unproven)"
own_lock "$HOME_DIR"
out=$(run_router "$ROOT_DIR" "$HOME_DIR" '{"source":"clear"}')
assert_contains "$out" "SESSION START - $HOME_DIR" "clear without completion proof did not run the full digest"
assert_not_contains "$out" 'CONTEXT RE-EMIT' "clear without completion proof must not re-emit"
pass "clear after a truncated startup finishes startup instead of re-emitting"

# --- source routing: clear and compact re-emit after a proven startup ----------
IFS='|' read -r ROOT_DIR HOME_DIR <<<"$(new_world clear-proven)"
own_lock "$HOME_DIR"
printf '%s\n' "$FIXTURE_PID" > "$HOME_DIR/state/.session-start-complete"
out=$(run_router "$ROOT_DIR" "$HOME_DIR" '{"source":"clear"}')
assert_contains "$out" "SESSION START (CONTEXT RE-EMIT) - $HOME_DIR" "a proven clear did not re-emit"
own_lock "$HOME_DIR"
out=$(run_router "$ROOT_DIR" "$HOME_DIR" '{"source":"compact"}')
assert_contains "$out" "SESSION START (CONTEXT RE-EMIT) - $HOME_DIR" "a proven compact did not re-emit"
pass "clear and compact re-emit only for the lock owner with completion proof"

# --- source routing: a foreign completion pid is not proof ---------------------
IFS='|' read -r ROOT_DIR HOME_DIR <<<"$(new_world clear-foreign)"
own_lock "$HOME_DIR"
printf '%s\n' 99999999 > "$HOME_DIR/state/.session-start-complete"
out=$(run_router "$ROOT_DIR" "$HOME_DIR" '{"source":"clear"}')
assert_contains "$out" "SESSION START - $HOME_DIR" "a mismatched completion pid did not force a full digest"
assert_not_contains "$out" 'CONTEXT RE-EMIT' "a mismatched completion pid must not re-emit"
pass "a completion record from another owner never gates a re-emit"

# --- source routing: resume/reload/fork nudge, and stay silent when owned ------
IFS='|' read -r ROOT_DIR HOME_DIR <<<"$(new_world resume)"
own_lock "$HOME_DIR"
for src in resume reload fork; do
  out=$(run_router "$ROOT_DIR" "$HOME_DIR" "{\"source\":\"$src\"}")
  [ -z "$out" ] || fail "source=$src with an owned lock must be silent, got: $out"
done
rm -f "$HOME_DIR/state/.lock"
out=$(run_router "$ROOT_DIR" "$HOME_DIR" '{"source":"resume"}')
# shellcheck disable=SC2016 # literal backticks in the nudge text
assert_contains "$out" 'Run `bin/cs-session-start.sh` now, exactly once' "resume without an owned lock did not nudge"
assert_not_contains "$out" 'SESSION START' "resume must nudge, not run the digest"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "the nudge must be one line, got: $out"
prefix_hex=$(printf '%s' "$out" | head -c 3 | od -An -tx1 | tr -d ' \n')
[ "$prefix_hex" = e281a3 ] || fail "the nudge lost its U+2063 operational marker: $prefix_hex"
out=$(run_router "$ROOT_DIR" "$HOME_DIR" '' --source resume)
# shellcheck disable=SC2016 # literal backticks in the nudge text
assert_contains "$out" 'Run `bin/cs-session-start.sh` now, exactly once' "--source resume did not nudge"
pass "resume, reload, and fork delegate to one typed nudge line"

# --- eligibility: a gate agent and an unmarked linked worktree are silent ------
IFS='|' read -r ROOT_DIR HOME_DIR <<<"$(new_world gate)"
out=$(printf '%s' '{"source":"startup"}' \
  | NO_MISTAKES_GATE=1 CS_ROOT_OVERRIDE="$ROOT_DIR" CS_HOME="$HOME_DIR" "$RUN")
[ -z "$out" ] || fail "NO_MISTAKES_GATE must be silent, got: $out"

WT_BASE="$TMP/wt-base"
WT_CHILD="$TMP/wt-child"
cs_git_worktree "$WT_BASE" "$WT_CHILD" cs/sessionstart-linked
mkdir -p "$WT_CHILD/bin"
: > "$WT_CHILD/AGENTS.md"
WT_HOME="$TMP/wt-home"
mkdir -p "$WT_HOME/state"
out=$(printf '%s' '{"source":"startup"}' \
  | CS_ROOT_OVERRIDE="$WT_CHILD" CS_HOME="$WT_HOME" "$RUN")
[ -z "$out" ] || fail "an unmarked linked worktree must be silent, got: $out"
pass "a gate agent and an unmarked linked task worktree never start a session"

# --- runtime bound: loud truncation, exit 0, no completion, no strays ----------
IFS='|' read -r ROOT_DIR HOME_DIR <<<"$(new_world bound)"
HANGBIN="$TMP/bound/hangbin"
mkdir -p "$HANGBIN"
cat > "$HANGBIN/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -C ] && [ "${3:-}" = rev-parse ] && [ "${4:-}" = --show-toplevel ]; then
  printf '%s\n' "$2"
  exit 0
fi
trap '' TERM
sleep 600
SH
chmod +x "$HANGBIN/git"

mechanism=$(CS_TIMEOUT_MECHANISM_OVERRIDE=bash bash -c '. "$1"; cs_timeout_mechanism' \
  _ "$ROOT/bin/cs-timeout-lib.sh")
[ "$mechanism" = bash ] || fail "the forced pure-Bash timeout fixture selected '$mechanism'"

status=0
out=$(cd "$ROOT_DIR" && \
  CS_TIMEOUT_MECHANISM_OVERRIDE=bash CS_SESSION_START_TIMEOUT=3 \
  CS_ROOT_OVERRIDE="$ROOT_DIR" CS_HOME="$HOME_DIR" \
  PATH="$HANGBIN:$BASH_BIN_DIR:$BASE_PATH" "$SESSION_START") || status=$?
expect_code 0 "$status" "a truncated session start must still exit 0 so the session can open"
assert_contains "$out" "SESSION START - $HOME_DIR" "the truncated digest lost the output it had already produced"
assert_contains "$out" 'lock acquired' "the truncated digest lost a stage that had completed"
assert_contains "$out" 'STARTUP TRUNCATED' "a truncated session start did not say so"
assert_not_contains "$out" 'BASH_FLOOR:' "ordinary truncation must not trigger the fatal bash-floor blocker"
assert_contains "$out" 'RUNTIME BOUND' "the truncation banner did not name the bound it hit"
assert_contains "$out" 'STALLED during the "bootstrap" stage' "the truncation banner did not name the stalled stage"
assert_contains "$out" 'wake-queue supervision read-once fleet-state network-checks context next-step' \
  "the truncation banner did not list every stage that never ran"
assert_contains "$out" 'READ-ONCE CONTRACT does not cover' \
  "the truncation banner did not void the read-once trust for the missing stages"
assert_not_contains "$out" 'NEXT STEP' "a truncated digest claimed to have reached its closing reminder"
assert_absent "$HOME_DIR/state/.session-start-complete" \
  "a truncated startup recorded itself as complete"
sleep 1
stray=$(pgrep -f "$HANGBIN/git" 2>/dev/null | wc -l | tr -d ' ')
[ "$stray" -eq 0 ] || fail "the runtime bound left $stray hung subprocess(es) behind"
pass "the runtime bound truncates loudly, names stalled and never-run stages, and exits 0"

# --- a digest that finishes in time records completion and no banner -----------
IFS='|' read -r ROOT_DIR HOME_DIR <<<"$(new_world in-time)"
out=$(run_session_start "$ROOT_DIR" "$HOME_DIR")
assert_not_contains "$out" 'STARTUP TRUNCATED' "a digest that finished in time reported itself truncated"
assert_contains "$out" 'NEXT STEP' "a full digest lost its closing reminder"
assert_present "$HOME_DIR/state/.session-start-complete" \
  "a completed locked startup did not record its completion proof"
lock_pid=$(cat "$HOME_DIR/state/.lock")
completion_pid=$(cat "$HOME_DIR/state/.session-start-complete")
[ "$completion_pid" = "$lock_pid" ] || \
  fail "completion proof pid ($completion_pid) does not match the lock owner ($lock_pid)"
pass "a completed locked startup records completion proof matching the lock owner"

# --- --reemit: lock re-verified, wakes drained, sweeps skipped, repair kept ----
REEMIT_W="$TMP/reemit"
ROOT_DIR="$REEMIT_W/root"
HOME_DIR="$REEMIT_W/home"
mkdir -p "$ROOT_DIR/bin" "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects"
# A tangled primary: a named non-default branch, so bootstrap's TANGLE line
# shows whose job the restore is.
git init -q -b main "$ROOT_DIR"
git -C "$ROOT_DIR" commit -q --allow-empty -m init
git -C "$ROOT_DIR" checkout -q -b cs/tangled-branch
: > "$ROOT_DIR/AGENTS.md"
# A stuck project clone: fleet sync (a mutating bootstrap sweep) reports it
# loudly on a full run, so its silence is what proves the re-emit skipped the
# sweep.
STUCK_ORIGIN="$REEMIT_W/origin"
cs_git_init_commit "$STUCK_ORIGIN"
git -C "$STUCK_ORIGIN" checkout -q -b main 2>/dev/null || git -C "$STUCK_ORIGIN" branch -q -m main
git clone -q "$STUCK_ORIGIN" "$HOME_DIR/projects/stuckproj"
git -C "$HOME_DIR/projects/stuckproj" checkout -q -b sidetrack
printf 'more\n' >> "$STUCK_ORIGIN/README.md"
git -C "$STUCK_ORIGIN" -c user.name=t -c user.email=t@example.invalid commit -qam advance

STARTUP_NETWORK="$ROOT/bin/cs-startup-network.sh"
# Harvest, not report: harvesting is what the digest itself does at step 7, and
# it is the only reader that records the delivery. Reading with `report` would
# leave the result unacknowledged, so whether the next startup's report carries
# this one forward would depend on which of the digest and its worker finished
# first - a race neither assertion below is about.
network_report() {
  CS_ROOT_OVERRIDE="$ROOT_DIR" CS_HOME="$HOME_DIR" "$STARTUP_NETWORK" wait 120 >/dev/null 2>&1 || true
  CS_ROOT_OVERRIDE="$ROOT_DIR" CS_HOME="$HOME_DIR" "$STARTUP_NETWORK" harvest 2>&1
}

full=$(run_session_start "$ROOT_DIR" "$HOME_DIR")
assert_present "$HOME_DIR/state/.session-start-complete" "the full startup did not record completion"
assert_contains "$full" 'NETWORK CHECKS' "the full startup lost its network-checks section"
# Fleet sync now runs in the deferred network stage (bin/cs-startup-network.sh),
# off the blocking session-open path, so its result is asserted where it lands
# rather than inline in the digest, which never waits for it.
full_network=$(network_report)
assert_contains "$full_network" 'FLEET_SYNC:' "the full startup did not run the fleet-sync sweep"
assert_contains "$full_network" 'STUCK' "the stuck clone fixture did not trip fleet sync"

printf '1723000000\t1\tsignal\treemit-task\tqueued after startup\n' > "$HOME_DIR/state/.wake-queue"
reemit=$(run_session_start "$ROOT_DIR" "$HOME_DIR" --reemit)
assert_contains "$reemit" "SESSION START (CONTEXT RE-EMIT) - $HOME_DIR" "--reemit did not label itself"
assert_contains "$reemit" 'lock acquired' "--reemit did not re-verify lock ownership"
assert_contains "$reemit" 'reemit-task' "--reemit did not drain the queued wake"
grep -q 'reemit-task' "$HOME_DIR/state/.wake-queue" 2>/dev/null && \
  fail "--reemit left the drained wake behind: $(cat "$HOME_DIR/state/.wake-queue")"
# The re-emit's deferred stage is the read-only probe alone, so the sweep the
# startup already ran must not appear in its report either.
reemit_network=$(network_report)
assert_not_contains "$reemit_network" 'FLEET_SYNC:' "--reemit repeated a mutating sweep startup already ran"
assert_contains "$reemit" 'restore the primary with' \
  "--reemit deferred tangle repair to a lock holder that is itself"
assert_not_contains "$reemit" 'leave restore work to the session holding the fleet lock' \
  "--reemit disclaimed repair ownership it still holds"
assert_contains "$reemit" 'READ-ONCE CONTRACT' "--reemit dropped the read-once contract"
assert_contains "$reemit" 'FLEET STATE' "--reemit dropped the fleet-state digest"
assert_contains "$reemit" 'CONTEXT' "--reemit dropped the context digest"
assert_contains "$reemit" 'NEXT STEP' "--reemit dropped the closing reminder"
pass "--reemit re-verifies the lock, drains wakes, skips sweeps, and keeps repair ownership"

# --- bootstrap repair ownership: detect-only defers, detect-only+locked keeps --
tangle_unlocked=$(CS_BOOTSTRAP_DETECT_ONLY=1 CS_ROOT_OVERRIDE="$ROOT_DIR" CS_HOME="$HOME_DIR" \
  "$ROOT/bin/cs-bootstrap.sh")
assert_contains "$tangle_unlocked" 'leave restore work to the session holding the fleet lock' \
  "an unlocked detect-only bootstrap must defer tangle repair"
tangle_locked=$(CS_BOOTSTRAP_DETECT_ONLY=1 CS_BOOTSTRAP_LOCKED=1 CS_ROOT_OVERRIDE="$ROOT_DIR" CS_HOME="$HOME_DIR" \
  "$ROOT/bin/cs-bootstrap.sh")
assert_contains "$tangle_locked" 'restore the primary with' \
  "a locked detect-only bootstrap must keep tangle repair ownership"
pass "CS_BOOTSTRAP_LOCKED decides tangle repair ownership under detect-only"

# --- hook entries: they fire at home and stay inert in a foreign checkout ------
FOREIGN="$TMP/foreign"
cs_git_init_commit "$FOREIGN"

# A plain checkout shaped like a consigliere primary home, so the tracked hook
# commands can be executed for real: this repo's own checkout under test is
# often a linked worktree, which the primary-scope guard correctly excludes.
HOOK_ROOT="$TMP/hook-home/root"
HOOK_HOME="$TMP/hook-home/home"
mkdir -p "$HOOK_ROOT" "$HOOK_HOME/state" "$HOOK_HOME/data" "$HOOK_HOME/config"
git init -q -b main "$HOOK_ROOT"
git -C "$HOOK_ROOT" commit -q --allow-empty -m init
: > "$HOOK_ROOT/AGENTS.md"
: > "$HOOK_ROOT/CLAUDE.md"
ln -s "$ROOT/bin" "$HOOK_ROOT/bin"
mkdir -p "$HOOK_ROOT/.claude" "$HOOK_ROOT/.codex"
cp "$ROOT/.claude/settings.json" "$HOOK_ROOT/.claude/settings.json"
cp "$ROOT/.codex/hooks.json" "$HOOK_ROOT/.codex/hooks.json"

for hooks_file in "$ROOT/.claude/settings.json" "$ROOT/.codex/hooks.json"; do
  cmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$hooks_file")
  status=0
  out=$(cd "$FOREIGN" && printf '%s' '{"source":"startup"}' | eval "$cmd" 2>&1) || status=$?
  expect_code 0 "$status" "the SessionStart hook from $hooks_file must exit 0 outside this repo"
  [ -z "$out" ] || fail "the SessionStart hook from $hooks_file must be silent outside this repo, got: $out"

  rm -f "$HOOK_HOME/state/.lock" "$HOOK_HOME/state/.session-start-complete"
  status=0
  out=$(
    cd "$HOOK_ROOT" \
      && export CS_ROOT_OVERRIDE="$HOOK_ROOT" CS_HOME="$HOOK_HOME" \
      && printf '%s' '{"source":"startup"}' | eval "$cmd" 2>/dev/null
  ) || status=$?
  expect_code 0 "$status" "the SessionStart hook from $hooks_file must exit 0 in a consigliere home"
  assert_contains "$out" "SESSION START - $HOOK_HOME" \
    "the SessionStart hook from $hooks_file did not run the digest in a consigliere home"
done
pass "the tracked session-open hook entries run the digest at home and stay inert elsewhere"

# --- the bound reports an unavailable mechanism as never-ran, not as a stall ---
IFS='|' read -r ROOT_DIR HOME_DIR <<<"$(new_world unbounded)"
# A temp dir that does not exist is the portable way to make every mktemp in
# the bounded runner fail, whatever uid the suite runs as.
NOTMP="$TMP/no-such-temp-dir/nested"
status=0
out=$(cd "$ROOT_DIR" && TMPDIR="$NOTMP" CS_TIMEOUT_MECHANISM_OVERRIDE=bash \
  CS_ROOT_OVERRIDE="$ROOT_DIR" CS_HOME="$HOME_DIR" "$SESSION_START") || status=$?
expect_code 0 "$status" "an unestablished bound must still exit 0 so the session can open"
assert_contains "$out" 'STARTUP DID NOT RUN' \
  "a digest that could not be bounded did not say it never ran"
assert_not_contains "$out" 'STALLED during' \
  "a digest that never ran was reported as a stall"
assert_absent "$HOME_DIR/state/.session-start-complete" \
  "a digest that never ran recorded itself as complete"
pass "a bound that cannot be established is reported as never-ran, never as a stall"

printf 'all cs-sessionstart-run tests passed\n'
