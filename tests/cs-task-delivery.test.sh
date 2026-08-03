#!/usr/bin/env bash
# Behavior (portable): a ship task's delivery posture is an explicit per-task
# decision, cross-checked between the brief and the spawn, and recorded once.
#
# Before this contract, cs-brief.sh and cs-spawn.sh each read the mode out of the
# data/projects.md registry, independently, at two different moments, with nothing
# comparing the two reads. A registry edit between scaffold and dispatch, or a
# brief adjusted by hand, left the worker following one contract while consigliere
# supervised off another - and the posture was never a per-task decision at all.
#
# This suite pins, as regressions:
#   - every refusal: a missing or out-of-set --mode/--yolo on cs-brief.sh,
#     cs-spawn.sh, and cs-promote.sh; --mode/--yolo offered to a scout or capo;
#     --yolo offered to any brief at all;
#   - the exact "Delivery contract: mode=<mode>" literal, and its placement at the
#     very end of the ship brief, past everything a caller rewrites for {TASK};
#   - the brief/spawn mismatch refusal, leaving no endpoint, workspace, worktree,
#     branch, or metadata behind (herdr worktree create is never even reached);
#   - the warn-and-launch path for a ship brief scaffolded before the contract;
#   - a scout's metadata carrying no mode= and no yolo= at all, and its consumers
#     tolerating that;
#   - the advisory registry-deviation notice: printed only when the explicit mode
#     carries LESS rigor than a registered standing posture, and never for a
#     project absent from the registry.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$ROOT/bin/cs-meta-lib.sh"
# shellcheck source=bin/cs-delivery-lib.sh
. "$ROOT/bin/cs-delivery-lib.sh"

BRIEF_BIN="$ROOT/bin/cs-brief.sh"
SPAWN="$ROOT/bin/cs-spawn.sh"
PROMOTE="$ROOT/bin/cs-promote.sh"
MERGE_LOCAL="$ROOT/bin/cs-merge-local.sh"
VIEW="$ROOT/bin/cs-fleet-view.sh"

TMP=$(cs_test_tmproot cs-task-delivery)
FAKEBIN=$(cs_fakebin "$TMP")
cs_git_identity

HOME_DIR="$TMP/home"
DATA="$HOME_DIR/data"
STATE="$HOME_DIR/state"
mkdir -p "$DATA" "$STATE" "$HOME_DIR/config"
printf 'manual\n' > "$HOME_DIR/config/backlog-backend"   # deterministic offline listing
export CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$DATA" CS_STATE_OVERRIDE="$STATE"

# `strict` is registered no-mistakes (the most rigor), `relaxed` local-only (the
# least). `unregistered` deliberately has no entry, which is the consigliere repo's
# own situation: no standing posture to deviate from, and nothing to warn about.
cat > "$DATA/projects.md" <<'EOF'
- strict - full pipeline (added 2026-08-01)
- relaxed [local-only] - local fixture (added 2026-08-01)
EOF

# --- fake herdr: enough for a real spawn, and a record of what was called -----
# CS_FAKE_HERDR_CALLS collects the lifecycle verbs, so a refusal that must happen
# BEFORE the worktree exists can be proven by absence rather than inferred.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s %s\n' "${1:-}" "${2:-}" >> "$CS_FAKE_HERDR_CALLS"
case "${1:-} ${2:-}" in
  "status --json") printf '%s\n' '{"server":{"protocol":16}}' ;;
  "worktree create")
    repo= branch=
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --cwd) repo=$2; shift ;;
        --branch) branch=$2; shift ;;
      esac
      shift
    done
    git -C "$repo" worktree add -q -b "$branch" "$CS_FAKE_SPAWN_WORKTREE"
    printf '{"result":{"workspace":{"workspace_id":"w1"},"root_pane":{"pane_id":"w1:p1"},"worktree":{"path":"%s","branch":"%s"}}}\n' "$CS_FAKE_SPAWN_WORKTREE" "$branch"
    ;;
  "pane run") printf '%s' "${4:-}" > "$CS_FAKE_SPAWN_LAUNCH" ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
  "agent get") printf '{"result":{"agent":{"agent":"codex","agent_status":"idle"}}}\n' ;;
  *) printf '{}\n' ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

cat > "$FAKEBIN/cs-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'state: working · source: none · fake\n'
SH
chmod +x "$FAKEBIN/cs-crew-state.sh"

REPO="$TMP/strict"
cs_git_init_commit "$REPO"

CALLS="$TMP/herdr-calls"
: > "$CALLS"

# run_spawn <id> <project-dir> [args...] -> combined output; exit code in $RC
run_spawn() {
  local id=$1 proj=$2
  shift 2
  RC=0
  OUT=$(env PATH="$FAKEBIN:$PATH" \
    CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$DATA" CS_STATE_OVERRIDE="$STATE" \
    CS_CLAUDE_JSON="$TMP/claude.json" \
    CS_FAKE_HERDR_CALLS="$CALLS" \
    CS_FAKE_SPAWN_WORKTREE="$TMP/wt-$id" CS_FAKE_SPAWN_LAUNCH="$TMP/launch-$id" \
    "$SPAWN" "$id" "$proj" "$@" 2>&1) || RC=$?
}

# refuse <label> <command...>: the command must exit non-zero, and its output is
# left in $OUT for the caller to assert on.
refuse() {
  local label=$1
  shift
  RC=0
  OUT=$("$@" 2>&1) || RC=$?
  [ "$RC" -ne 0 ] || fail "$label: expected a refusal, got exit 0"$'\n'"--- output ---"$'\n'"$OUT"
}

# --- 1. cs-brief.sh requires an in-set --mode on a ship scaffold --------------

refuse "ship brief with no --mode" "$BRIEF_BIN" b-nomode strict
assert_contains "$OUT" "--mode" "the missing-mode refusal names the flag"
assert_contains "$OUT" "no-mistakes|direct-PR|local-only" "the refusal names the closed set"
assert_absent "$DATA/b-nomode" "a refused scaffold leaves no task directory behind"

refuse "ship brief with an out-of-set --mode" "$BRIEF_BIN" b-badmode strict --mode yolo-mode
assert_contains "$OUT" "got 'yolo-mode'" "the invalid-mode refusal quotes the value"
assert_absent "$DATA/b-badmode" "an invalid mode leaves no task directory behind"
pass "cs-brief.sh refuses a ship scaffold with a missing or out-of-set --mode"

# --- 2. --mode is refused where there is no delivery mode to state ------------

refuse "scout brief with --mode" "$BRIEF_BIN" b-scoutmode strict --scout --mode no-mistakes
assert_contains "$OUT" "applies only to ship briefs" "the scout refusal explains why"
refuse "capo charter with --mode" "$BRIEF_BIN" b-capomode --capo strict --mode no-mistakes
assert_contains "$OUT" "applies only to ship briefs" "the capo refusal explains why"
pass "cs-brief.sh refuses --mode on a scout or capo scaffold"

# --- 3. --yolo never reaches a brief -----------------------------------------
# yolo governs consigliere's own approval behaviour, so the worker's contract has
# no business carrying it. Before the explicit refusal, an unrecognized --yolo
# fell through to the positional collector and was silently ignored.
for variant in "--yolo on" "--yolo=on"; do
  # shellcheck disable=SC2086  # deliberate word split: each variant is a flag form
  refuse "ship brief with $variant" "$BRIEF_BIN" b-yolo strict --mode no-mistakes $variant
  assert_contains "$OUT" "not a brief flag" "the yolo refusal names the rule ($variant)"
done
refuse "scout brief with --yolo" "$BRIEF_BIN" b-yolo-scout strict --scout --yolo off
assert_contains "$OUT" "not a brief flag" "the scout yolo refusal names the rule"
refuse "capo charter with --yolo" "$BRIEF_BIN" b-yolo-capo --capo strict --yolo off
assert_contains "$OUT" "not a brief flag" "the capo yolo refusal names the rule"
assert_absent "$DATA/b-yolo" "a refused yolo scaffold leaves no task directory behind"
pass "cs-brief.sh refuses --yolo on every scaffold instead of ignoring it"

# --- 4. the exact contract line, in a placement {TASK} cannot clobber ---------
# The literal is pinned here, not derived from the library, because cs-spawn.sh's
# cross-check depends on these exact bytes surviving in both directions.
[ "$CS_DELIVERY_CONTRACT_PREFIX" = 'Delivery contract: mode=' ] \
  || fail "the delivery-contract line prefix changed: '$CS_DELIVERY_CONTRACT_PREFIX'"
for mode in no-mistakes direct-PR local-only; do
  "$BRIEF_BIN" "c-$mode" strict --mode "$mode" >/dev/null || fail "ship scaffold ($mode) failed"
  B="$DATA/c-$mode/brief.md"
  assert_grep "Delivery contract: mode=$mode" "$B" "brief records the contract line ($mode)"
  last=$(grep -v '^[[:space:]]*$' "$B" | tail -1)
  [ "$last" = "Delivery contract: mode=$mode" ] \
    || fail "the contract line must be the brief's last non-blank line ($mode), got: $last"
  # {TASK} sits at the top under "# Task"; the contract line is past the whole
  # body a caller rewrites, so filling the brief in cannot displace it.
  task_ln=$(grep -n '^{TASK}$' "$B" | head -1 | cut -d: -f1)
  contract_ln=$(grep -n "^Delivery contract: mode=$mode\$" "$B" | head -1 | cut -d: -f1)
  [ -n "$task_ln" ] || fail "ship brief ($mode) lost its {TASK} placeholder line"
  [ "$task_ln" -lt "$contract_ln" ] \
    || fail "the contract line must sit after the {TASK} placeholder ($mode)"
done
pass "a ship brief ends with the exact machine-readable delivery-contract line"

"$BRIEF_BIN" c-scout strict --scout >/dev/null || fail "scout scaffold failed"
assert_no_grep 'Delivery contract: mode=' "$DATA/c-scout/brief.md" \
  "a scout brief carries no delivery contract"
CS_CAPO_CHARTER='Own the fixture domain.' "$BRIEF_BIN" c-capo --capo strict >/dev/null \
  || fail "capo scaffold failed"
assert_no_grep 'Delivery contract: mode=' "$DATA/c-capo/brief.md" \
  "a capo charter carries no delivery contract"
pass "scout and capo scaffolds carry no delivery contract at all"

# --- 5. cs-spawn.sh requires an in-set --mode and --yolo on a ship spawn ------

mkdir -p "$DATA/s-flags"
cs_delivery_contract_line no-mistakes > "$DATA/s-flags/brief.md"

run_spawn s-flags "$REPO"
[ "$RC" -ne 0 ] || fail "a ship spawn with no --mode must refuse"
assert_contains "$OUT" "requires --mode" "the missing-mode refusal names the flag"
assert_absent "$STATE/s-flags.meta" "a refused spawn publishes no metadata"

run_spawn s-flags "$REPO" --mode no-mistakes
[ "$RC" -ne 0 ] || fail "a ship spawn with no --yolo must refuse"
assert_contains "$OUT" "requires --yolo" "the missing-yolo refusal names the flag"

run_spawn s-flags "$REPO" --mode sometimes --yolo off
[ "$RC" -ne 0 ] || fail "an out-of-set --mode must refuse"
assert_contains "$OUT" "got 'sometimes'" "the invalid-mode refusal quotes the value"

run_spawn s-flags "$REPO" --mode no-mistakes --yolo maybe
[ "$RC" -ne 0 ] || fail "an out-of-set --yolo must refuse"
assert_contains "$OUT" "got 'maybe'" "the invalid-yolo refusal quotes the value"

assert_absent "$STATE/s-flags.meta" "no flag refusal publishes metadata"
assert_no_grep 'worktree create' "$CALLS" "no flag refusal reaches herdr worktree create"
pass "cs-spawn.sh refuses a ship spawn with a missing or out-of-set --mode/--yolo"

# --- 6. posture flags are refused for a scout or capo spawn ------------------

run_spawn c-scout "$REPO" --scout --mode no-mistakes
[ "$RC" -ne 0 ] || fail "--mode on a scout spawn must refuse"
assert_contains "$OUT" "applies only to ship spawns" "the scout --mode refusal explains why"
run_spawn c-scout "$REPO" --scout --yolo on
[ "$RC" -ne 0 ] || fail "--yolo on a scout spawn must refuse"
assert_contains "$OUT" "applies only to ship spawns" "the scout --yolo refusal explains why"

CAPO_HOME="$TMP/capo-home"
mkdir -p "$CAPO_HOME"
: > "$CAPO_HOME/.cs-capo-home"
run_spawn c-capo "$CAPO_HOME" --capo --mode no-mistakes
[ "$RC" -ne 0 ] || fail "--mode on a capo spawn must refuse"
assert_contains "$OUT" "applies only to ship spawns" "the capo --mode refusal explains why"
run_spawn c-capo "$CAPO_HOME" --capo --yolo off
[ "$RC" -ne 0 ] || fail "--yolo on a capo spawn must refuse"
assert_contains "$OUT" "applies only to ship spawns" "the capo --yolo refusal explains why"
assert_absent "$STATE/c-capo.meta" "a refused capo spawn publishes no metadata"
pass "cs-spawn.sh refuses --mode/--yolo on a scout or capo spawn"

# --- 7. a brief/spawn mode mismatch is impossible to launch through ----------
# The refusal must land before the herdr worktree exists, so it never strands an
# endpoint, workspace, or branch that a later spawn of the same id would trip on.
: > "$CALLS"
run_spawn c-direct-PR "$REPO" --mode local-only --yolo off
[ "$RC" -ne 0 ] || fail "a brief/spawn mode mismatch must refuse"
assert_contains "$OUT" "Delivery contract: mode=direct-PR" "the mismatch names the brief's recorded mode"
assert_contains "$OUT" "--mode local-only" "the mismatch names the mode the spawn passed"
assert_absent "$STATE/c-direct-PR.meta" "a mismatch publishes no metadata"
assert_absent "$TMP/wt-c-direct-PR" "a mismatch leaves no worktree behind"
assert_no_grep 'worktree create' "$CALLS" "a mismatch never reaches herdr worktree create"
git -C "$REPO" show-ref --verify --quiet refs/heads/cs/c-direct-PR \
  && fail "a mismatch must leave no task branch behind"
pass "a brief/spawn delivery-mode mismatch refuses before anything is created"

# --- 8. a pre-contract ship brief warns once and launches on the flag --------
mkdir -p "$DATA/s-legacy"
printf 'implement the fixture\n' > "$DATA/s-legacy/brief.md"
run_spawn s-legacy "$REPO" --mode no-mistakes --yolo off
[ "$RC" -eq 0 ] || fail "a pre-contract brief must launch, not refuse: $OUT"
assert_contains "$OUT" "carries no 'Delivery contract: mode=<mode>' line" \
  "the compatibility path names what is missing"
assert_contains "$OUT" "launching on --mode no-mistakes" "the warning names the mode it launched on"
[ "$(printf '%s\n' "$OUT" | grep -c "carries no 'Delivery contract")" = 1 ] \
  || fail "the pre-contract brief must warn exactly once"
[ "$(cs_meta_get "$STATE/s-legacy.meta" mode)" = no-mistakes ] || fail "s-legacy meta mode"
[ "$(cs_meta_get "$STATE/s-legacy.meta" yolo)" = off ] || fail "s-legacy meta yolo"
# Positive control for the "never reaches herdr worktree create" assertions above:
# a spawn that DOES proceed records that call, so their absence means something.
assert_grep 'worktree create' "$CALLS" "a proceeding spawn records the worktree create call"
pass "a ship brief scaffolded before the contract warns once and launches on the flag"

# --- 9. a ship spawn records the stated posture; a scout records none --------
run_spawn c-no-mistakes "$REPO" --mode no-mistakes --yolo on
[ "$RC" -eq 0 ] || fail "matched ship spawn failed: $OUT"
assert_contains "$OUT" "kind=ship mode=no-mistakes yolo=on" "the spawn reports the recorded posture"
[ "$(cs_meta_get "$STATE/c-no-mistakes.meta" mode)" = no-mistakes ] || fail "ship meta mode"
[ "$(cs_meta_get "$STATE/c-no-mistakes.meta" yolo)" = on ] || fail "ship meta yolo"

run_spawn c-scout "$REPO" --scout
[ "$RC" -eq 0 ] || fail "scout spawn failed: $OUT"
assert_not_contains "$OUT" "mode=" "a scout spawn reports no delivery mode"
assert_not_contains "$OUT" "yolo=" "a scout spawn reports no approval posture"
assert_no_grep 'mode=' "$STATE/c-scout.meta" "a scout's metadata records no mode="
assert_no_grep 'yolo=' "$STATE/c-scout.meta" "a scout's metadata records no yolo="
assert_grep 'kind=scout' "$STATE/c-scout.meta" "the scout metadata is otherwise complete"
pass "ship metadata records the explicit posture; scout metadata records none"

# --- 10. the meta consumers tolerate a scout with no posture -----------------
# Everything that greps mode=/yolo= out of metadata must read an absent field as
# absent, not crash and not invent a default that changes a decision.
RC=0
OUT=$(env PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" \
  CS_CREW_STATE_BIN="$FAKEBIN/cs-crew-state.sh" \
  CS_FAKE_HERDR_CALLS="$CALLS" \
  "$VIEW" --json 2>&1) || RC=$?
[ "$RC" -eq 0 ] || fail "the fleet review must render a posture-less scout: $OUT"
scout_json=$(printf '%s' "$OUT" | jq -r '.tasks[] | select(.id == "c-scout") | "\(.kind)|\(.mode)|\(.yolo)"')
[ "$scout_json" = 'scout||' ] || fail "the fleet review must render an absent posture as empty, got: $scout_json"

RC=0
OUT=$(env PATH="$FAKEBIN:$PATH" "$MERGE_LOCAL" c-scout 2>&1) || RC=$?
[ "$RC" -ne 0 ] || fail "the local merge path must refuse a scout task"
assert_contains "$OUT" "<none recorded>" "the local-merge refusal reports an absent mode as absent"
assert_not_contains "$OUT" "is mode=, not" "an absent mode must not read as an empty mode"
pass "the metadata consumers read an absent scout posture as absent"

# --- 11. the registry stays advisory: a downward deviation is a notice -------
RELAXED="$TMP/relaxed"
cs_git_init_commit "$RELAXED"
UNREG="$TMP/unregistered"
cs_git_init_commit "$UNREG"

# strict is registered no-mistakes; shipping it local-only is less rigor.
"$BRIEF_BIN" d-down strict --mode local-only >/dev/null || fail "d-down scaffold failed"
run_spawn d-down "$REPO" --mode local-only --yolo off
[ "$RC" -eq 0 ] || fail "a downward deviation must continue, not refuse: $OUT"
assert_contains "$OUT" "notice:" "a downward deviation prints a notice"
assert_contains "$OUT" "standing registry posture is no-mistakes" "the notice names the standing posture"
assert_contains "$OUT" "advisory" "the notice says the registry is advisory"

# Same mode as the registry: nothing to report.
"$BRIEF_BIN" d-same strict --mode no-mistakes >/dev/null || fail "d-same scaffold failed"
run_spawn d-same "$REPO" --mode no-mistakes --yolo off
[ "$RC" -eq 0 ] || fail "a matching mode must spawn: $OUT"
assert_not_contains "$OUT" "notice:" "a mode matching the registry prints no notice"

# relaxed is registered local-only; shipping it no-mistakes is MORE rigor, which
# is never worth a notice.
"$BRIEF_BIN" d-up relaxed --mode no-mistakes >/dev/null || fail "d-up scaffold failed"
run_spawn d-up "$RELAXED" --mode no-mistakes --yolo off
[ "$RC" -eq 0 ] || fail "an upward deviation must spawn: $OUT"
assert_not_contains "$OUT" "notice:" "more rigor than the registry prints no notice"
pass "a downward registry deviation is a notice and never blocks the spawn"

# --- 12. an unregistered project has no standing posture --------------------
# The consigliere repo itself is exactly this case: absent from data/projects.md
# on purpose, so its spawns must be quiet - no deviation notice, and no leaked
# "not in registry" warning implying something is wrong.
"$BRIEF_BIN" d-unreg unregistered --mode local-only >/dev/null || fail "d-unreg scaffold failed"
run_spawn d-unreg "$UNREG" --mode local-only --yolo off
[ "$RC" -eq 0 ] || fail "an unregistered project must spawn: $OUT"
assert_not_contains "$OUT" "notice:" "an unregistered project has no posture to deviate from"
assert_not_contains "$OUT" "not in registry" "an unregistered project raises no registry warning"
assert_not_contains "$OUT" "warn:" "an unregistered project spawns quietly"
pass "an unregistered project spawns quietly with no standing posture"

# --- 13. promotion is where a scout first states its ship posture ------------
cs_write_meta "$STATE/p1.meta" "project=$REPO" "pane=w1:p1" "kind=scout"

refuse "promotion with no posture" "$PROMOTE" p1
assert_contains "$OUT" "requires --mode" "the promotion refusal names the missing flag"
assert_contains "$OUT" "no delivery posture to inherit" "the refusal explains why nothing can be derived"
assert_grep 'kind=scout' "$STATE/p1.meta" "a refused promotion leaves the metadata untouched"

refuse "promotion with no --yolo" "$PROMOTE" p1 --mode direct-PR
assert_contains "$OUT" "requires --yolo" "the promotion refusal names the missing yolo flag"
refuse "promotion with an out-of-set mode" "$PROMOTE" p1 --mode fast --yolo off
assert_contains "$OUT" "got 'fast'" "the invalid-mode refusal quotes the value"
refuse "promotion with an out-of-set yolo" "$PROMOTE" p1 --mode direct-PR --yolo sometimes
assert_contains "$OUT" "got 'sometimes'" "the invalid-yolo refusal quotes the value"
assert_grep 'kind=scout' "$STATE/p1.meta" "no promotion refusal mutates the metadata"

"$PROMOTE" p1 --mode direct-PR --yolo on >/dev/null || fail "promotion failed"
[ "$(cs_meta_get "$STATE/p1.meta" kind)" = ship ] || fail "promotion must flip kind to ship"
[ "$(cs_meta_get "$STATE/p1.meta" mode)" = direct-PR ] || fail "promotion must record the mode"
[ "$(cs_meta_get "$STATE/p1.meta" yolo)" = on ] || fail "promotion must record the yolo posture"
pass "cs-promote.sh requires an explicit posture and records it in the task metadata"

pass "explicit per-task delivery contract"
