#!/usr/bin/env bash
# tests/cs-fleet-view.test.sh - the read-only fleet review (bin/cs-fleet-view.sh).
# Drives the real script offline with a fake herdr CLI (pane get / agent get /
# pane read / status) and a fake cs-crew-state.sh via CS_CREW_STATE_BIN, the
# same seams the cs-watch suite uses. Asserts: the markdown review renders the
# backlog compact listing, every state/<id>.meta with endpoint liveness and
# current state, the keyed open-decision fold, scout report and PR pointers,
# and marker-validated capo home summaries (unknown, never guessed, for an
# unmarked or missing home); a headless scout row is labeled so its endpoint
# never implies a steerable pane; --json emits the same data under the
# cs-fleet-view.v1 schema; and the command mutates nothing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VIEW="$ROOT/bin/cs-fleet-view.sh"

TMP_ROOT=$(cs_test_tmproot cs-fleet-view)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(cs_fakebin "$TMP_ROOT")

# --- fake herdr: pane presence + native agent status, offline ----------------
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
# Offline herdr stand-in. Env:
#   CS_FAKE_PANES               space-separated pane ids that exist
#   CS_FAKE_HERDR_AGENT_STATUS  agent_status for `agent get` (default working)
set -u
case "${1:-} ${2:-}" in
  "pane get")
    case " ${CS_FAKE_PANES:-} " in
      *" ${3:-} "*) printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$3"; exit 0 ;;
      *) exit 1 ;;
    esac ;;
  "pane read")
    exit 0 ;;
  "agent get")
    printf '{"result":{"agent":{"agent":"codex","agent_status":"%s"}}}\n' \
      "${CS_FAKE_HERDR_AGENT_STATUS:-working}"
    exit 0 ;;
  "status --json")
    printf '{"server":{"protocol":16,"socket":""}}\n'
    exit 0 ;;
esac
exit 1
SH
chmod +x "$FAKEBIN/herdr"

# --- fake cs-crew-state.sh: canned authoritative verdicts per id -------------
cat > "$FAKEBIN/cs-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=${1:-}
key=$(printf '%s' "$id" | tr -c 'A-Za-z0-9' '_')
var="CS_FAKE_CREW_STATE_$key"
val=${!var:-${CS_FAKE_CREW_STATE:-}}
printf '%s\n' "${val:-state: unknown · source: none · fake default}"
exit 0
SH
chmod +x "$FAKEBIN/cs-crew-state.sh"

# --- fixture home: backlog, task metas, statuses, reports, capo registry -----
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/t2" "$HOME_DIR/config" "$HOME_DIR/host" \
  "$TMP_ROOT/wt1" "$TMP_ROOT/wt2"
printf 'manual\n' > "$HOME_DIR/config/backlog-backend.conf"   # deterministic offline listing

cat > "$HOME_DIR/config/backlog.md" <<'MD'
# Backlog

## In flight

- [ ] t1 - Fix the flux capacitor (repo: proj)

## Queued

- [ ] q1 - Later thing (blocked-by: t1)

## Done

- [x] d1 - Landed thing (merged 2026-07-20)
MD

cs_write_meta "$HOME_DIR/state/t1.meta" \
  "workspace=w1" "pane=w1:p1" "worktree=$TMP_ROOT/wt1" "project=$TMP_ROOT/proj" \
  "kind=ship" "mode=no-mistakes" "yolo=off" "pr=https://github.com/x/y/pull/7"
printf 'working: setup\nneeds-decision [key=api]: choose A or B\nworking: continuing\n' \
  > "$HOME_DIR/state/t1.status"

cs_write_meta "$HOME_DIR/state/t2.meta" \
  "workspace=w2" "pane=w2:p1" "worktree=$TMP_ROOT/wt2" "project=$TMP_ROOT/proj" \
  "kind=scout" "mode=no-mistakes" "yolo=off"
printf 'done: report ready\n' > "$HOME_DIR/state/t2.status"
printf '# findings\n' > "$HOME_DIR/data/t2/report.md"

# t3: recorded pane is gone (endpoint dead), no status file.
cs_write_meta "$HOME_DIR/state/t3.meta" \
  "workspace=w3" "pane=w3:p1" "worktree=$TMP_ROOT/gone" "project=$TMP_ROOT/proj" \
  "kind=ship" "mode=direct-PR" "yolo=on"

# t4: a headless scout (codex exec / claude -p). Its pane exists but presents no
# steerable TUI; the render must label it so the endpoint does not imply a steer.
mkdir -p "$TMP_ROOT/wt4" "$HOME_DIR/data/t4"
cs_write_meta "$HOME_DIR/state/t4.meta" \
  "workspace=w4" "pane=w4:p1" "worktree=$TMP_ROOT/wt4" "project=$TMP_ROOT/proj" \
  "kind=scout" "mode=no-mistakes" "yolo=off" "headless=1"
printf 'done: headless scout finished; read the report\n' > "$HOME_DIR/state/t4.status"
printf '# headless findings\n' > "$HOME_DIR/data/t4/report.md"

# Capo homes: alpha is valid+marked, beta lacks the marker, gamma is missing.
mkdir -p "$TMP_ROOT/capoA/state" "$TMP_ROOT/capoA/config" "$TMP_ROOT/capoB"
: > "$TMP_ROOT/capoA/.cs-capo-home"
cs_write_meta "$TMP_ROOT/capoA/state/childx.meta" "pane=w9:p1" "kind=ship"
cat > "$TMP_ROOT/capoA/config/backlog.md" <<'MD'
## In flight

- [ ] c1 - Capo child work

## Queued

- [ ] c2 - Queued capo item
- [ ] c3 - Second queued capo item

## Done
MD

cat > "$HOME_DIR/host/capos.md" <<MD
# Capos

- alpha (home: $TMP_ROOT/capoA; scope: infra work)
- beta (home: $TMP_ROOT/capoB; scope: web)
- gamma (home: $TMP_ROOT/capoC; scope: lost)
MD

run_view() {  # [flags...] -> stdout; exit code in $RC
  RC=0
  OUT=$(env PATH="$FAKEBIN:$PATH" \
    CS_HOME="$HOME_DIR" \
    CS_CREW_STATE_BIN="$FAKEBIN/cs-crew-state.sh" \
    CS_FAKE_PANES="w1:p1 w2:p1 w4:p1" \
    CS_FAKE_HERDR_AGENT_STATUS=working \
    CS_FAKE_CREW_STATE_t1='state: working · source: run-step · validating (running)' \
    CS_FAKE_CREW_STATE_t2='state: done · source: status-log · report ready' \
    CS_FAKE_CREW_STATE_t4='state: done · source: status-log · report ready' \
    CS_FLEET_NOW=2026-07-22T00:00:00Z \
    "$VIEW" "$@") || RC=$?
}

fs_inventory() {  # stable file+size inventory of the whole fixture tree
  find "$TMP_ROOT" -path "$TMP_ROOT/fakebin" -prune -o -type f -print \
    | sort | while IFS= read -r f; do
        printf '%s %s\n' "$f" "$(wc -c < "$f" | tr -d ' ')"
      done
}

# --- human markdown review ----------------------------------------------------

test_markdown_review() {
  local before after
  before=$(fs_inventory)
  run_view
  after=$(fs_inventory)
  expect_code 0 "$RC" "default fleet view"
  assert_contains "$OUT" "# Fleet Review" "review header missing"

  # Backlog compact listing and headline counts.
  assert_contains "$OUT" "## Backlog (1 in flight, 1 queued, 1 done)" "backlog headline counts wrong"
  assert_contains "$OUT" "Fix the flux capacitor" "in-flight backlog title line missing"
  assert_contains "$OUT" "Later thing" "queued backlog title line missing"

  # Every meta rendered with endpoint liveness + authoritative current state.
  assert_contains "$OUT" "| t1 | ship | working (run-step) | present / busy |" "t1 task row wrong"
  assert_contains "$OUT" "https://github.com/x/y/pull/7" "t1 PR pointer missing"
  assert_contains "$OUT" "| t2 | scout | done (status-log) | present / busy |" "t2 task row wrong"
  assert_contains "$OUT" "$HOME_DIR/data/t2/report.md" "t2 scout report pointer missing"
  assert_contains "$OUT" "| t3 | ship | unknown (none) | ABSENT |" "t3 dead-endpoint row wrong"

  # A headless scout is labeled so the endpoint never implies a steerable pane;
  # the interactive scout t2 above stays unlabeled (exact row asserted).
  assert_contains "$OUT" "| t4 | scout | done (status-log) | present / busy · headless (not steerable) |" "t4 headless row not labeled"

  # Keyed open-decision fold: the later working: line must not mask it.
  assert_contains "$OUT" "- t1 [key=api] needs-decision: choose A or B" "open keyed decision missing"
  assert_not_contains "$OUT" "t2 [key=" "scout with no open decision leaked one"

  # Capos: valid home summarized, invalid/missing homes are unknown, never guessed.
  assert_contains "$OUT" "| alpha | ok | 1 | 1/2/0 |" "valid capo summary wrong"
  assert_contains "$OUT" "| beta | unknown | - | - |" "unmarked capo home not classified unknown"
  assert_contains "$OUT" "not a marked capo home" "unmarked capo home reason missing"
  assert_contains "$OUT" "| gamma | unknown | - | - |" "missing capo home not classified unknown"
  assert_contains "$OUT" "home directory missing" "missing capo home reason missing"

  [ "$before" = "$after" ] || fail "default view mutated the fixture tree"$'\n'"--- before ---"$'\n'"$before"$'\n'"--- after ---"$'\n'"$after"
  pass "markdown review renders backlog, tasks, liveness, decisions, pointers, and capos read-only"
}

# --- --json parity -------------------------------------------------------------

test_json_snapshot() {
  local before after
  before=$(fs_inventory)
  run_view --json
  after=$(fs_inventory)
  expect_code 0 "$RC" "--json fleet view"
  printf '%s' "$OUT" | jq -e '.schema == "cs-fleet-view.v1"' >/dev/null \
    || fail "--json schema is not cs-fleet-view.v1"
  printf '%s' "$OUT" | jq -e '
    (.tasks | length) == 4
    and (.backlog.present and .backlog.counts.in_flight == 1 and .backlog.counts.queued == 1 and .backlog.counts.done == 1)
    and ((.backlog.listing | join("\n")) | contains("Fix the flux capacitor"))
  ' >/dev/null || fail "--json backlog/tasks shape wrong: $OUT"
  printf '%s' "$OUT" | jq -e '
    (.tasks[] | select(.id == "t1")) as $t
    | $t.kind == "ship"
      and $t.endpoint.exists == true and $t.endpoint.agent == "busy"
      and $t.current_state.state == "working" and $t.current_state.source == "run-step"
      and $t.pr == "https://github.com/x/y/pull/7"
      and ($t.open_decisions | length) == 1
      and $t.open_decisions[0].key == "api"
      and $t.open_decisions[0].verb == "needs-decision"
  ' >/dev/null || fail "--json t1 record wrong: $OUT"
  printf '%s' "$OUT" | jq -e '
    (.tasks[] | select(.id == "t2")) as $t
    | $t.kind == "scout" and $t.report.present == true and $t.pr == null
      and ($t.open_decisions | length) == 0 and $t.headless == false
  ' >/dev/null || fail "--json t2 record wrong: $OUT"
  printf '%s' "$OUT" | jq -e '
    (.tasks[] | select(.id == "t4")) as $t
    | $t.kind == "scout" and $t.headless == true
      and $t.endpoint.exists == true and $t.report.present == true
  ' >/dev/null || fail "--json t4 headless record wrong: $OUT"
  printf '%s' "$OUT" | jq -e '
    (.tasks[] | select(.id == "t3")) as $t
    | $t.endpoint.exists == false and $t.current_state.state == "unknown"
  ' >/dev/null || fail "--json t3 record wrong: $OUT"
  printf '%s' "$OUT" | jq -e '
    .capos.present == true and (.capos.records | length) == 3 and (.capos.truncated | not)
    and (.capos.records[] | select(.id == "alpha")
         | .state == "ok" and .children_in_flight == 1
           and .backlog.in_flight == 1 and .backlog.queued == 2 and .backlog."done" == 0)
    and (.capos.records[] | select(.id == "beta")
         | .state == "unknown" and .children_in_flight == null and (.reason | contains(".cs-capo-home")))
    and (.capos.records[] | select(.id == "gamma")
         | .state == "unknown" and (.reason | contains("missing")))
  ' >/dev/null || fail "--json capo records wrong: $OUT"
  [ "$before" = "$after" ] || fail "--json view mutated the fixture tree"
  pass "--json emits the same data under cs-fleet-view.v1, read-only"
}

# --- capo bound + usage --------------------------------------------------------

test_capo_bound_disclosed() {
  run_view --json
  local bounded
  bounded=$(env PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" \
    CS_CREW_STATE_BIN="$FAKEBIN/cs-crew-state.sh" CS_FAKE_PANES="w1:p1 w2:p1" \
    CS_FLEET_CAPOS=1 CS_FLEET_NOW=2026-07-22T00:00:00Z "$VIEW" --json) \
    || fail "bounded capo view exited non-zero"
  printf '%s' "$bounded" | jq -e '
    (.capos.records | length) == 1 and .capos.truncated == true
  ' >/dev/null || fail "CS_FLEET_CAPOS bound not applied/disclosed: $bounded"
  pass "the capo registry read is bounded and discloses truncation"
}

# --- registry read fails closed -------------------------------------------------

test_registry_reads_fail_closed() {
  local reg="$HOME_DIR/host/capos.md" saved
  saved=$(cat "$reg")

  # A registry whose last line has no trailing newline must keep its last capo.
  # Dropping it made a registered capo vanish from the review while the same
  # snapshot still reported truncated:false - a silent, unattributable loss.
  printf -- '- alpha (home: %s; scope: infra work)\n- gamma (home: %s; scope: lost)' \
    "$TMP_ROOT/capoA" "$TMP_ROOT/capoC" > "$reg"
  run_view --json
  expect_code 0 "$RC" "no-trailing-newline registry view"
  printf '%s' "$OUT" | jq -e '
    (.capos.records | length) == 2
    and ((.capos.records | map(.id)) == ["alpha","gamma"])
    and (.capos.truncated | not)
  ' >/dev/null || fail "the last capo was dropped when the registry had no trailing newline: $OUT"

  # A row that does not parse is rendered as a visible unknown, never skipped.
  printf -- '- alpha (home: %s; scope: infra work)\n- wrecked - no structured suffix\n' \
    "$TMP_ROOT/capoA" > "$reg"
  run_view --json
  printf '%s' "$OUT" | jq -e '
    (.capos.records | length) == 2
    and (.capos.records[1] | .id == null and .state == "unknown"
         and (.reason | contains("malformed registry entry")))
  ' >/dev/null || fail "a malformed capo row was dropped instead of surfaced: $OUT"
  run_view
  assert_contains "$OUT" "malformed registry entry" "the markdown review must show the malformed row"

  # A symlinked registry is refused, never followed.
  printf '%s\n' "$saved" > "$TMP_ROOT/capos-target.md"
  rm -f "$reg"
  ln -s "$TMP_ROOT/capos-target.md" "$reg"
  run_view --json
  expect_code 0 "$RC" "symlinked registry view"
  printf '%s' "$OUT" | jq -e '
    .capos.present == true and (.capos.records | length) == 0
    and (.capos.error | contains("symlink"))
  ' >/dev/null || fail "a symlinked registry was followed or silently reported zero: $OUT"
  rm -f "$reg"
  printf '%s\n' "$saved" > "$reg"

  # An unreadable registry must never read as "this fleet has no capos".
  if [ "$(id -u)" = 0 ]; then
    pass "unreadable-registry check skipped: running as root, where the mode bits do not apply"
  else
    chmod 000 "$reg"
    run_view --json
    expect_code 0 "$RC" "unreadable registry view"
    printf '%s' "$OUT" | jq -e '
      .capos.present == true and (.capos.records | length) == 0
      and (.capos.error | contains("unreadable"))
    ' >/dev/null || fail "an unreadable registry silently reported zero capos: $OUT"
    run_view
    assert_contains "$OUT" "UNREADABLE capo registry" "the markdown review must say the registry could not be read"
    assert_not_contains "$OUT" "Registry present, no registered capos." \
      "an unreadable registry must never render as an empty fleet"
    chmod 644 "$reg"
  fi

  printf '%s\n' "$saved" > "$reg"
  pass "the capo registry read fails closed: EOF-safe, malformed rows surfaced, symlink and unreadable refused"
}

test_usage_errors() {
  run_view --bogus
  expect_code 2 "$RC" "unknown flag"
  run_view --help
  expect_code 0 "$RC" "--help"
  assert_contains "$OUT" "usage: cs-fleet-view.sh" "--help usage text missing"
  pass "usage errors exit 2 and --help documents the contract"
}

# --- absent registry is the empty set, not a gap --------------------------------

test_absent_registry_is_not_a_gap() {
  local reg="$HOME_DIR/host/capos.md" saved
  saved=$(cat "$reg")
  rm -f "$reg"

  # A home that never provisioned a capo has no registry, and that is healthy:
  # the review must read it as zero capos, never as a missing artifact.
  run_view
  expect_code 0 "$RC" "absent-registry view"
  assert_contains "$OUT" "No capos provisioned from this home." \
    "absent registry must render as the empty set"
  assert_not_contains "$OUT" "No capo registry" \
    "absent registry must not be reported as a missing file"
  run_view --json
  printf '%s' "$OUT" | jq -e '
    .capos.present == false and (.capos.records | length) == 0 and .capos.error == null
  ' >/dev/null || fail "absent registry JSON must stay present:false with no error: $OUT"

  printf '%s\n' "$saved" > "$reg"
  pass "an absent capo registry renders as zero capos provisioned, not a gap"
}

test_markdown_review
test_json_snapshot
test_capo_bound_disclosed
test_registry_reads_fail_closed
test_absent_registry_is_not_a_gap
test_usage_errors
