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
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/t2" "$HOME_DIR/config" \
  "$TMP_ROOT/wt1" "$TMP_ROOT/wt2"
printf 'manual\n' > "$HOME_DIR/config/backlog-backend"   # deterministic offline listing

cat > "$HOME_DIR/data/backlog.md" <<'MD'
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
mkdir -p "$TMP_ROOT/capoA/state" "$TMP_ROOT/capoA/data" "$TMP_ROOT/capoB"
: > "$TMP_ROOT/capoA/.cs-capo-home"
cs_write_meta "$TMP_ROOT/capoA/state/childx.meta" "pane=w9:p1" "kind=ship"
cat > "$TMP_ROOT/capoA/data/backlog.md" <<'MD'
## In flight

- [ ] c1 - Capo child work

## Queued

- [ ] c2 - Queued capo item
- [ ] c3 - Second queued capo item

## Done
MD

cat > "$HOME_DIR/data/capos.md" <<MD
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

test_usage_errors() {
  run_view --bogus
  expect_code 2 "$RC" "unknown flag"
  run_view --help
  expect_code 0 "$RC" "--help"
  assert_contains "$OUT" "usage: cs-fleet-view.sh" "--help usage text missing"
  pass "usage errors exit 2 and --help documents the contract"
}

test_markdown_review
test_json_snapshot
test_capo_bound_disclosed
test_usage_errors
