#!/usr/bin/env bash
# Behavior: cs-vault-cascade.sh, the enumeration and routing half of a /vault
# sweep across the capo homes. Covers registry enumeration (every registered
# capo exactly once, malformed and duplicated rows reported rather than
# dropped), per-home startup-memory budget accounting, the live-vs-inert
# routing decision, and the per-home hard bound that turns a wedged home into
# an exception without stopping the sweep. Hermetic: herdr is faked.
set -u
# shellcheck source=tests/capo-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/capo-helpers.sh"

TMP=$(cs_test_tmproot cs-vault-cascade)
BIN="$ROOT/bin/cs-vault-cascade.sh"

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/host" "$HOME_DIR/state" "$HOME_DIR/data"

export CS_ROOT_OVERRIDE="$TMP/fake-root"
mkdir -p "$CS_ROOT_OVERRIDE"
export CS_HOME="$HOME_DIR"
export CS_STARTUP_MEMORY_MAX_BYTES=200
export CS_VAULT_CASCADE_STEP_TIMEOUT=20

REG="$HOME_DIR/host/capos.md"

# A fake herdr with the two knobs this suite drives: whether a pane holds an
# agent, and whether a probe against one particular pane hangs (the wedged
# home). FAKE_PANE_CWD_<pane> lets one case pin a recycled pane id to a
# different home.
FAKEBIN=$(cs_fakebin "$TMP")
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
pane=${3:-}
if [ -n "${FAKE_HANG_PANE:-}" ] && [ "$pane" = "$FAKE_HANG_PANE" ]; then
  sleep 120
  exit 0
fi
agent_var="FAKE_AGENT_${pane//[:]/_}"
agent=${!agent_var:-}
cwd_var="FAKE_CWD_${pane//[:]/_}"
cwd=${!cwd_var:-}
case "${1:-} ${2:-}" in
  "status --json") echo '{"server":{"running":true,"protocol":17,"socket":""}}' ;;
  "pane get")
    # A genuinely absent pane answers with the structured pane_not_found body on
    # stderr (rc 1), exactly as the real herdr does; an unreachable server emits
    # non-JSON noise instead. The distinction is the whole point of the probe.
    if [ -n "${FAKE_PANE_GONE:-}" ] && [ "$pane" = "$FAKE_PANE_GONE" ]; then
      echo '{"error":{"code":"pane_not_found","message":"no such pane"}}' >&2
      exit 1
    fi
    if [ -n "${FAKE_PANE_GET_ERROR_PANE:-}" ] && [ "$pane" = "$FAKE_PANE_GET_ERROR_PANE" ]; then
      echo 'Error: Os { code: 2, kind: NotFound, message: "No such file or directory" }' >&2
      exit 1
    fi
    printf '{"result":{"pane":{"pane_id":"%s","cwd":"%s"}}}\n' "$pane" "$cwd" ;;
  "agent get")
    if [ -n "${FAKE_AGENT_GET_FAIL_PANE:-}" ] && [ "$pane" = "$FAKE_AGENT_GET_FAIL_PANE" ]; then exit 1; fi
    if [ -n "$agent" ]; then
      printf '{"result":{"agent":{"agent":"%s","agent_status":"idle"}}}\n' "$agent"
    else
      echo '{"result":{"agent":{}}}'
    fi ;;
  *) echo '{}' ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/herdr"
export PATH="$FAKEBIN:$PATH"

# cs_capo_home <id> <pane> - a seeded-looking capo home plus this home's own
# direct-report record for it. Memory files are sized deliberately:
# learnings.md is over the 200-byte budget, boss-shared.md is under it, and
# boss.md is absent.
cs_capo_home() {
  local id=$1 pane=$2 home
  home="$TMP/capos/$id"
  mkdir -p "$home/config"
  printf '%s\n' "$id" > "$home/.cs-capo-home"
  printf 'shared preference\n' > "$home/config/boss-shared.md"
  head -c 400 /dev/zero | tr '\0' 'x' > "$home/config/learnings.md"
  cs_write_meta "$HOME_DIR/state/$id.meta" \
    "pane=$pane" "kind=capo" "mode=capo" "yolo=off" "harness=codex" "home=$home"
  printf '%s\n' "$home"
}

LIVE_HOME=$(cs_capo_home live w1:p1)
INERT_HOME=$(cs_capo_home inert w2:p1)
export FAKE_AGENT_w1_p1=codex
export FAKE_CWD_w1_p1=$LIVE_HOME
export FAKE_CWD_w2_p1=$INERT_HOME

# --- no registry -------------------------------------------------------------

OUT=$("$BIN" 2>&1); RC=$?
expect_code 0 "$RC" "a home with no capo registry reports an empty sweep"
assert_contains "$OUT" "capos: 0 registered" "an absent registry is an empty sweep, not an error"
assert_contains "$OUT" "summary: 0 send, 0 curate, 0 exception" "the empty sweep still summarizes"
pass "no registry: empty sweep, exit 0"

# --- enumeration, budget accounting, and routing ------------------------------

cs_capo_registry_write "$REG" \
  "$(cs_capo_registry_line live 'live domain' "$LIVE_HOME" 'live work')" \
  "$(cs_capo_registry_line inert 'inert domain' "$INERT_HOME" 'inert work')" \
  "- this row is malformed" \
  "$(cs_capo_registry_line live 'duplicate row' "$LIVE_HOME" 'live work')"

OUT=$("$BIN" 2>&1); RC=$?
expect_code 0 "$RC" "a sweep that ran exits 0 whatever the homes reported"

assert_contains "$OUT" "capos: 4 registered" "every registry row is counted"
[ "$(printf '%s\n' "$OUT" | grep -c '^capo: live$')" = 1 ] \
  || fail "the live capo must be enumerated exactly once"$'\n'"$OUT"
assert_line "$OUT" '^capo: inert$' "the inert capo is enumerated"

# Malformed and duplicated rows are reported, never silently dropped.
assert_contains "$OUT" "malformed registry entry: - this row is malformed" \
  "a malformed registry row is surfaced as an exception"
assert_contains "$OUT" "capo live has more than one registry entry" \
  "a duplicated id is refused rather than swept twice"

# Per-home, per-file budget accounting against this home's own budget.
assert_line "$OUT" '^  memory: config/boss\.md absent$' "an absent memory file is reported as absent"
assert_line "$OUT" '^  memory: config/boss-shared\.md [0-9]+/200 under$' "an under-budget file reports under"
assert_line "$OUT" '^  memory: config/learnings\.md 400/200 OVER$' "an over-budget file reports OVER"
assert_line "$OUT" '^  archive: config/memory-archive\.md absent \(cold tier' \
  "the cold tier is reported for orientation, never against the budget"
assert_contains "$OUT" "sizes are never summed across homes" \
  "the report states the per-home budget rule it applies"

# Live home -> ask its own agent; inert home -> curate in place.
LIVE_BLOCK=$(printf '%s\n' "$OUT" | awk '/^capo: live$/{f=1;next} /^capo: /{f=0} f')
assert_line "$LIVE_BLOCK" '^  route: send$' "a home with a live agent is asked to sweep itself"
assert_contains "$LIVE_BLOCK" "cs-send.sh\" live '\$vault" \
  "the send goes through the ordinary marked cs-send path, in the target harness's skill syntax"
assert_contains "$LIVE_BLOCK" "CS_HOME=\"$HOME_DIR\"" \
  "the send is issued from the invoking home, quoted so a path with a space still runs"

INERT_BLOCK=$(printf '%s\n' "$OUT" | awk '/^capo: inert$/{f=1;next} /^capo: /{f=0} f')
assert_line "$INERT_BLOCK" '^  route: curate$' "a home with no live agent is curated in place"
assert_contains "$INERT_BLOCK" "no agent in pane w2:p1" "the curate decision names its evidence"

assert_contains "$OUT" "summary: 1 send, 1 curate, 2 exception" "the summary counts every route"
pass "enumeration, budget accounting, and live-vs-inert routing"

# --- a probe that cannot answer is an exception, never a curate ---------------

OUT=$(FAKE_AGENT_GET_FAIL_PANE=w1:p1 "$BIN" 2>&1)
LIVE_BLOCK=$(printf '%s\n' "$OUT" | awk '/^capo: live$/{f=1;next} /^capo: /{f=0} f')
assert_line "$LIVE_BLOCK" '^  route: exception$' \
  "an inconclusive liveness probe must not become a curate behind a live capo's back"
assert_contains "$LIVE_BLOCK" "liveness probe for w1:p1 failed" "the exception names the probe"

# The pane probe itself erroring (an unreachable server) is not proof of death:
# the same failure exit carries a pane_not_found body only when the pane is
# truly gone, so an errored probe must resolve to exception, never curate.
OUT=$(FAKE_PANE_GET_ERROR_PANE=w1:p1 "$BIN" 2>&1)
LIVE_BLOCK=$(printf '%s\n' "$OUT" | awk '/^capo: live$/{f=1;next} /^capo: /{f=0} f')
assert_line "$LIVE_BLOCK" '^  route: exception$' \
  "an unreachable herdr must never read as a confirmed-absent pane"
assert_no_line "$LIVE_BLOCK" '^  route: curate$' \
  "an errored probe must not curate behind a live capo's back"
assert_contains "$LIVE_BLOCK" "pane probe for w1:p1 could not answer" "the exception names the probe"

# A pane that answers without a readable cwd cannot prove it still roots at
# this home, so the send leg is unproven and the route is an exception.
OUT=$(FAKE_CWD_w1_p1= "$BIN" 2>&1)
LIVE_BLOCK=$(printf '%s\n' "$OUT" | awk '/^capo: live$/{f=1;next} /^capo: /{f=0} f')
assert_line "$LIVE_BLOCK" '^  route: exception$' \
  "a pane with no readable cwd is an unproven root, never a send"
assert_contains "$LIVE_BLOCK" "no readable cwd" "the exception names the missing proof"

# A recycled pane id belongs to another home, so there is nobody to ask here.
OUT=$(FAKE_CWD_w1_p1="$TMP/somewhere-else" "$BIN" 2>&1)
LIVE_BLOCK=$(printf '%s\n' "$OUT" | awk '/^capo: live$/{f=1;next} /^capo: /{f=0} f')
assert_line "$LIVE_BLOCK" '^  route: curate$' "a recycled pane id is never asked to run /vault"
assert_contains "$LIVE_BLOCK" "the recorded id was recycled" "the recycled-pane decision says why"

# A gone pane is the same story with a different reason: only the structured
# pane_not_found body is positive proof of death.
OUT=$(FAKE_PANE_GONE=w2:p1 "$BIN" 2>&1)
INERT_BLOCK=$(printf '%s\n' "$OUT" | awk '/^capo: inert$/{f=1;next} /^capo: /{f=0} f')
assert_line "$INERT_BLOCK" '^  route: curate$' "a confirmed-gone pane routes to curate in place"
assert_contains "$INERT_BLOCK" "recorded pane w2:p1 no longer exists" "a vanished pane is reported as such"
pass "liveness: inconclusive probes, recycled panes, and vanished panes"

# --- no direct-report record --------------------------------------------------

mv "$HOME_DIR/state/inert.meta" "$TMP/inert.meta.bak"
OUT=$("$BIN" 2>&1)
INERT_BLOCK=$(printf '%s\n' "$OUT" | awk '/^capo: inert$/{f=1;next} /^capo: /{f=0} f')
assert_line "$INERT_BLOCK" '^  route: curate$' "a capo with no direct-report record here is curated in place"
assert_contains "$INERT_BLOCK" "no direct-report record for inert" "the reason names what is missing"
mv "$TMP/inert.meta.bak" "$HOME_DIR/state/inert.meta"
pass "a home with no direct-report record is curated, not guessed at"

# --- an unmarked home is an exception ------------------------------------------

mv "$INERT_HOME/.cs-capo-home" "$INERT_HOME/.marker.bak"
OUT=$("$BIN" 2>&1)
INERT_BLOCK=$(printf '%s\n' "$OUT" | awk '/^capo: inert$/{f=1;next} /^capo: /{f=0} f')
assert_line "$INERT_BLOCK" '^  route: exception$' "an unmarked home is never treated as a capo home"
assert_contains "$INERT_BLOCK" ".cs-capo-home missing" "the exception names the missing marker"
mv "$INERT_HOME/.marker.bak" "$INERT_HOME/.cs-capo-home"
pass "an unmarked home is an exception"

# --- the per-home bound: a wedged home does not stop the sweep -----------------

OUT=$(CS_VAULT_CASCADE_STEP_TIMEOUT=1 FAKE_HANG_PANE=w1:p1 "$BIN" 2>&1); RC=$?
expect_code 0 "$RC" "a wedged home does not fail the sweep"
LIVE_BLOCK=$(printf '%s\n' "$OUT" | awk '/^capo: live$/{f=1;next} /^capo: /{f=0} f')
assert_line "$LIVE_BLOCK" '^  route: exception$' "a home that outlives its bound is an exception"
assert_contains "$LIVE_BLOCK" "exceeded the 1s bound" "the exception names the bound it hit"
assert_no_line "$LIVE_BLOCK" '^  route: send$' \
  "partial output from a killed step must not be printed as a complete record"
INERT_BLOCK=$(printf '%s\n' "$OUT" | awk '/^capo: inert$/{f=1;next} /^capo: /{f=0} f')
assert_line "$INERT_BLOCK" '^  route: curate$' "the sweep continues past the wedged home"
pass "a wedged home reports an exception and the sweep continues"

# --- refusals -----------------------------------------------------------------

printf 'some-capo\n' > "$HOME_DIR/.cs-capo-home"
OUT=$("$BIN" 2>&1); RC=$?
expect_code 1 "$RC" "a capo home must not cascade"
assert_contains "$OUT" "only the primary home cascades" "the refusal explains the boundary"
rm -f "$HOME_DIR/.cs-capo-home"

rm -f "$REG"
ln -s "$TMP/elsewhere.md" "$REG"
OUT=$("$BIN" 2>&1); RC=$?
expect_code 1 "$RC" "an unreadable routing table fails closed"
assert_contains "$OUT" "it is NOT an empty fleet" \
  "an unreadable routing table must never read as a fleet with no capos"
pass "refusals: a capo home cannot cascade, an unreadable routing table fails closed"
