#!/usr/bin/env bash
# Behavior: cs-backlog-handoff.sh validated cross-home backlog moves. The
# helper owns the fleet-level validation (capo home resolution and marker
# proof, queued-only classification, idempotency, missing-key abort,
# non-canonical-body refusal) and delegates the actual block move to
# `tasks-axi mv`. Hermetic: tasks-axi is faked with a compatible version probe
# and a simple whole-block mover.
set -u
# shellcheck source=tests/capo-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/capo-helpers.sh"

TMP=$(cs_test_tmproot cs-backlog-handoff)
mkdir -p "$TMP"

BIN="$ROOT/bin/cs-backlog-handoff.sh"
HOME_DIR="$TMP/home"
CAPO="$TMP/capo-home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/host" "$HOME_DIR/projects"
mkdir -p "$CAPO/data" "$CAPO/state" "$CAPO/config" "$CAPO/host" "$CAPO/projects" "$CAPO/bin"
printf 'qa-capo\n' > "$CAPO/.cs-capo-home"
printf '# fixture\n' > "$CAPO/AGENTS.md"

export CS_ROOT_OVERRIDE="$TMP/fake-root"
mkdir -p "$CS_ROOT_OVERRIDE"
export CS_HOME="$HOME_DIR"
export CS_DATA_OVERRIDE="$HOME_DIR/data"

REG="$HOME_DIR/host/capos.md"
MAIN_BACKLOG="$HOME_DIR/config/backlog.md"
printf -- '- qa-capo - QA domain (home: %s; scope: qa work; projects: alpha; added 2026-01-01)\n' "$CAPO" > "$REG"

write_main_backlog() {
  cat > "$MAIN_BACKLOG" <<'EOF'
## In flight

- [ ] hot-task fix the login flow
  owned by a live soldier

## Queued

- [ ] qa-1 add smoke tests
  needs the staging env
  blocked-by: none
- [ ] qa-2 flaky test triage
- [ ] odd-1 oddly indented item
 single-space continuation line

## Done

- [x] old-1 archived work
EOF
}
write_main_backlog

# A fake tasks-axi: compatible probes plus a naive whole-block `mv` that
# appends each moved block to the destination and deletes it from the source.
FAKEBIN=$(cs_fakebin "$TMP")
cat > "$FAKEBIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  --version) echo "tasks-axi 0.2.2"; exit 0 ;;
  update) echo "usage: ... --archive-body ..."; exit 0 ;;
  mv)
    if [ "${2:-}" = "--help" ]; then echo "usage: tasks-axi mv [<id>...] --file <f> --to <t>"; exit 0; fi
    shift
    ids=()
    file= to=
    while [ $# -gt 0 ]; do
      case "$1" in
        --file) file=$2; shift 2 ;;
        --to) to=$2; shift 2 ;;
        *) ids+=("$1"); shift ;;
      esac
    done
    [ "${FAKE_TASKS_AXI_MV_FAIL:-0}" = 1 ] && { echo "mv: simulated failure"; exit 1; }
    for id in "${ids[@]}"; do
      block=$(awk -v key="$id" '
        /^- \[[ x]\] / {
          rest = $0; sub(/^- \[[ x]\] +/, "", rest); tid = rest; sub(/[ \t].*/, "", tid)
          if (capturing) exit
          if (tid == key) { capturing = 1; print; next }
          next
        }
        capturing && /^##[[:space:]]+/ { exit }
        capturing { print }
      ' "$file")
      [ -n "$block" ] || { echo "mv: $id not found"; exit 1; }
      printf '%s\n' "$block" >> "$to"
      awk -v key="$id" '
        /^- \[[ x]\] / {
          rest = $0; sub(/^- \[[ x]\] +/, "", rest); tid = rest; sub(/[ \t].*/, "", tid)
          if (tid == key) { skipping = 1; next }
          skipping = 0
        }
        /^##[[:space:]]+/ { skipping = 0 }
        skipping { next }
        { print }
      ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    done
    echo "moved ${#ids[@]} item(s)"
    exit 0 ;;
esac
exit 1
SH
chmod +x "$FAKEBIN/tasks-axi"
export PATH="$FAKEBIN:$PATH"

# 1. unregistered capo refuses
out=$("$BIN" ghost-capo qa-1 2>&1) && fail "unregistered capo must refuse"
assert_contains "$out" "not registered" "unregistered refusal names the registry"
pass "unregistered capo refuses"

# 2. marker mismatch refuses (home marked for someone else)
printf 'other-capo\n' > "$CAPO/.cs-capo-home"
out=$("$BIN" qa-capo qa-1 2>&1) && fail "marker mismatch must refuse"
assert_contains "$out" "marked for capo other-capo" "mismatch refusal names the marker owner"
printf 'qa-capo\n' > "$CAPO/.cs-capo-home"
pass "marker mismatch refuses"

# 3. missing marker refuses (destination is not a seeded capo home)
rm "$CAPO/.cs-capo-home"
out=$("$BIN" qa-capo qa-1 2>&1) && fail "missing marker must refuse"
assert_contains "$out" "not a seeded capo home" "missing-marker refusal is explicit"
printf 'qa-capo\n' > "$CAPO/.cs-capo-home"
pass "missing marker refuses (never lands in an unproven directory)"

# 4. in-flight and Done items refuse; nothing moves
out=$("$BIN" qa-capo hot-task 2>&1) && fail "in-flight handoff must refuse"
assert_contains "$out" "in-flight" "in-flight refusal is explicit"
assert_contains "$out" "nothing was moved" "refusal moves nothing"
out=$("$BIN" qa-capo old-1 2>&1) && fail "Done handoff must refuse"
assert_contains "$out" "Done (historical)" "Done refusal is explicit"
assert_grep '- [ ] hot-task' "$MAIN_BACKLOG" "in-flight item untouched"
pass "in-flight and Done items are refused with nothing moved"

# 5. any missing key aborts the whole set with nothing moved
out=$("$BIN" qa-capo qa-1 no-such-key 2>&1) && fail "missing key must abort"
assert_contains "$out" "no backlog item matched" "missing-key abort names the key"
assert_grep '- [ ] qa-1' "$MAIN_BACKLOG" "valid sibling key not moved on abort"
pass "a missing key aborts the whole handoff"

# 6. non-2-space continuation refuses rather than orphaning the body
out=$("$BIN" qa-capo odd-1 2>&1) && fail "non-canonical body must refuse"
assert_contains "$out" "non-2-space continuation" "non-canonical refusal names the line"
pass "non-canonical item bodies are refused"

# 7. happy path: queued items move atomically into the capo backlog
out=$("$BIN" qa-capo qa-1 qa-2 2>&1) || fail "handoff failed: $out"
assert_contains "$out" "handed off 2 item(s) to qa-capo" "handoff reports the moved set"
CAPO_BACKLOG="$CAPO/config/backlog.md"
assert_present "$CAPO_BACKLOG" "capo backlog scaffold created"
assert_grep '## Queued' "$CAPO_BACKLOG" "scaffold carries the standard sections"
assert_grep '- [ ] qa-1' "$CAPO_BACKLOG" "qa-1 moved into the capo backlog"
assert_grep 'needs the staging env' "$CAPO_BACKLOG" "item body moved with the header"
assert_grep '- [ ] qa-2' "$CAPO_BACKLOG" "qa-2 moved into the capo backlog"
assert_no_grep '- [ ] qa-1' "$MAIN_BACKLOG" "qa-1 removed from the main backlog"
assert_no_grep '- [ ] qa-2' "$MAIN_BACKLOG" "qa-2 removed from the main backlog"
pass "queued items hand off atomically via tasks-axi mv"

# 8. idempotent: an already-present key is skipped, exit 0
out=$("$BIN" qa-capo qa-1 2>&1) || fail "idempotent re-run failed: $out"
assert_contains "$out" "nothing to move" "already-present key reports a no-op"
pass "handoff is idempotent for already-moved keys"

# 9. a failed mv leaves both backlogs unchanged and removes only the scaffold
write_main_backlog
rm -f "$CAPO_BACKLOG"
cp "$MAIN_BACKLOG" "$TMP/main-before"
out=$(env FAKE_TASKS_AXI_MV_FAIL=1 "$BIN" qa-capo qa-1 2>&1) && fail "failed mv must fail the handoff"
assert_contains "$out" "nothing was moved" "failed mv reports nothing moved"
cmp -s "$MAIN_BACKLOG" "$TMP/main-before" || fail "failed mv must leave the main backlog unchanged"
assert_absent "$CAPO_BACKLOG" "failed mv removes only the scaffold it created"
pass "a failed tasks-axi mv changes nothing"

pass "cs-backlog-handoff validation and delegation"
