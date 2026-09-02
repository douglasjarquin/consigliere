#!/usr/bin/env bash
# tests/cs-context-pack.test.sh - bin/cs-context-pack.sh (issue #151 phase 2).
# Covers the phase's required-tests list: byte-identity across repeat runs,
# hash sensitivity to exactly the right component, the closed-set/fail-closed
# rejections (unknown role/workflow/harness, missing/traversal/symlink-escape/
# oversized component source), role-specific pack content, and that the
# persisted pack hash matches the bytes actually written.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PACK_BIN="$ROOT/bin/cs-context-pack.sh"
PACK_LIB="$ROOT/bin/cs-context-pack-lib.sh"

# --- 1. byte identity across every listed role/workflow/harness combination -
combos=$(bash "$PACK_BIN" --list)
[ -n "$combos" ] || fail "cs-context-pack.sh --list produced no combinations"
count=0
while IFS=' ' read -r role workflow harness; do
  [ -n "$role" ] || continue
  out1=$(cs_test_tmproot pack1)
  out2=$(cs_test_tmproot pack2)
  CS_CONTEXT_PACK_OUT_DIR="$out1" bash "$PACK_BIN" "$role" "$workflow" "$harness" >/dev/null 2>&1 \
    || fail "cs-context-pack.sh $role $workflow $harness failed on the first run"
  CS_CONTEXT_PACK_OUT_DIR="$out2" bash "$PACK_BIN" "$role" "$workflow" "$harness" >/dev/null 2>&1 \
    || fail "cs-context-pack.sh $role $workflow $harness failed on the second run"
  diff -q "$out1/pack.md" "$out2/pack.md" >/dev/null \
    || fail "$role $workflow $harness: pack.md differs across two runs with identical arguments"
  diff -q "$out1/pack.json" "$out2/pack.json" >/dev/null \
    || fail "$role $workflow $harness: pack.json differs across two runs with identical arguments"
  count=$((count + 1))
done <<EOF
$combos
EOF
pass "every listed role/workflow/harness combination is byte-identical across two runs ($count combinations)"

# --- 2. an exec-mode difference changes a ship pack's hash, plan-first names
#        the harness-specific skill (harness DOES matter, just only there) ---
out_u=$(cs_test_tmproot exec)
out_p=$(cs_test_tmproot exec)
CS_CONTEXT_PACK_OUT_DIR="$out_u" bash "$PACK_BIN" ship made claude --exec-mode ultrawork >/dev/null
CS_CONTEXT_PACK_OUT_DIR="$out_p" bash "$PACK_BIN" ship made claude --exec-mode plan-first >/dev/null
diff -q "$out_u/pack.md" "$out_p/pack.md" >/dev/null \
  && fail "ultrawork and plan-first ship packs must differ (plan-first adds a plan/start-work section)"
pass "exec-mode changes the ship pack (ultrawork vs plan-first differ)"

out_claude=$(cs_test_tmproot harness)
out_codex=$(cs_test_tmproot harness)
CS_CONTEXT_PACK_OUT_DIR="$out_claude" bash "$PACK_BIN" ship made claude --exec-mode plan-first >/dev/null
CS_CONTEXT_PACK_OUT_DIR="$out_codex" bash "$PACK_BIN" ship made codex --exec-mode plan-first >/dev/null
diff -q "$out_claude/pack.md" "$out_codex/pack.md" >/dev/null \
  && fail "claude and codex plan-first ship packs must differ (each names its own plan/start-work skill)"
pass "harness changes a plan-first ship pack (claude vs codex name different skills)"

# --- 3. component-level hash sensitivity: changing one fixture file changes
#        only its own component hash, never an unrelated file's -------------
FIXROOT=$(cs_test_tmproot fixroot)
mkdir -p "$FIXROOT/bin"
printf 'kernel v1\n' > "$FIXROOT/AGENTS.md"
printf 'harness facts v1\n' > "$FIXROOT/bin/cs-harness-lib.sh"
# shellcheck source=bin/cs-context-pack-lib.sh
. "$PACK_LIB"
kernel_before=$(cs_pack_resolve_component "$FIXROOT" AGENTS.md) || fail "resolve kernel before edit"
hash_kernel_before=$(cs_pack_sha256_of "$kernel_before")
harness_before=$(cs_pack_resolve_component "$FIXROOT" bin/cs-harness-lib.sh) || fail "resolve harness-facts before edit"
hash_harness_before=$(cs_pack_sha256_of "$harness_before")
printf 'kernel v2 - changed\n' > "$FIXROOT/AGENTS.md"
hash_kernel_after=$(cs_pack_sha256_of "$(cs_pack_resolve_component "$FIXROOT" AGENTS.md)")
hash_harness_after=$(cs_pack_sha256_of "$(cs_pack_resolve_component "$FIXROOT" bin/cs-harness-lib.sh)")
[ "$hash_kernel_before" != "$hash_kernel_after" ] || fail "editing AGENTS.md must change its own component hash"
[ "$hash_harness_before" = "$hash_harness_after" ] || fail "editing AGENTS.md must NOT change the unrelated harness-lib component's hash"
pass "changing one component changes only its own hash, never an unrelated component's"

# --- 4. fail-closed rejections -----------------------------------------------
out=$(cs_pack_resolve_component "$FIXROOT" does-not-exist.md 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "a missing component source must be rejected"
assert_contains "$out" "missing" "the missing-source error should say so"

out=$(cs_pack_resolve_component "$FIXROOT" ../outside.md 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "a path-traversal component source must be rejected"

mkdir -p "$(dirname "$FIXROOT")/escape-target"
printf 'outside the fixture root\n' > "$(dirname "$FIXROOT")/escape-target/secret.md"
ln -s "$(dirname "$FIXROOT")/escape-target/secret.md" "$FIXROOT/escape-link.md"
out=$(cs_pack_resolve_component "$FIXROOT" escape-link.md 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "a symlink escaping the fixture root must be rejected"
assert_contains "$out" "escapes" "the symlink-escape error should say so"

printf '%01000000d' 1 > "$FIXROOT/huge.md"
out=$(CS_CONTEXT_PACK_MAX_COMPONENT_BYTES=1000 cs_pack_resolve_component "$FIXROOT" huge.md 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "a component source over the byte cap must be rejected"
assert_contains "$out" "oversized" "the oversized error should say so"

out=$(bash "$PACK_BIN" bogus-role none claude 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "an unknown role must be rejected"
out=$(bash "$PACK_BIN" root bogus-workflow claude 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "an unknown workflow must be rejected"
out=$(bash "$PACK_BIN" ship made bogus-harness 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "an unknown harness must be rejected"
out=$(bash "$PACK_BIN" root none claude --exec-mode plan-first 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "--exec-mode on a non-ship role must be rejected"
out=$(bash "$PACK_BIN" ship bogus-workflow claude 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "a workflow outside a role's own closed set (ship + bogus) must be rejected"
out=$(bash "$PACK_BIN" root made claude 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "a real delivery mode used as root's workflow (root has none) must be rejected"
pass "unknown role, workflow, harness, missing/traversal/symlink-escape/oversized component all fail closed"

# --- 5. role-specific pack content: required rules present, unrelated absent -
outroot=$(cs_test_tmproot content)
CS_CONTEXT_PACK_OUT_DIR="$outroot" bash "$PACK_BIN" root none claude >/dev/null
assert_grep "You are the consigliere" "$outroot/pack.md" "root pack must carry the kernel's identity line"
assert_grep "Never merge a PR without the boss's explicit word" "$outroot/pack.md" "root pack must carry the merge-authority invariant"
assert_no_grep "Delivery contract: mode=" "$outroot/pack.md" "root pack must not carry a worker delivery contract"

outship=$(cs_test_tmproot content)
CS_CONTEXT_PACK_OUT_DIR="$outship" bash "$PACK_BIN" ship made claude >/dev/null
assert_grep "Delivery contract: mode=" "$outship/pack.md" "ship pack must carry its delivery contract"
assert_grep "Never merge a PR" "$outship/pack.md" "ship pack must still carry the never-merge rule"
assert_no_grep "You are the consigliere" "$outship/pack.md" "ship pack must not carry consigliere's own root identity"
assert_no_grep "Capo" "$outship/pack.md" "ship pack must not carry capo-only material"

outscout=$(cs_test_tmproot content)
CS_CONTEXT_PACK_OUT_DIR="$outscout" bash "$PACK_BIN" scout report-only grok >/dev/null
assert_no_grep "Delivery contract: mode=" "$outscout/pack.md" "scout pack must not carry a delivery contract (scout has no mode)"
assert_no_grep "You are the consigliere" "$outscout/pack.md" "scout pack must not carry consigliere's own root identity"

outcapo=$(cs_test_tmproot content)
CS_CONTEXT_PACK_OUT_DIR="$outcapo" bash "$PACK_BIN" capo none cursor >/dev/null
assert_no_grep "Delivery contract: mode=" "$outcapo/pack.md" "capo pack must not carry a ship delivery contract"
assert_no_grep "You are the consigliere" "$outcapo/pack.md" "capo pack must not carry consigliere's own root identity"
pass "root, ship, scout, and capo packs each carry their own required rules and exclude the others' unrelated material"

# --- 6. the persisted pack hash matches the bytes actually written ----------
for spec in "root none claude" "scout report-only grok" "ship local-only cursor" "capo none codex"; do
  read -r spec_role spec_workflow spec_harness <<< "$spec"
  outd=$(cs_test_tmproot hashcheck)
  CS_CONTEXT_PACK_OUT_DIR="$outd" bash "$PACK_BIN" "$spec_role" "$spec_workflow" "$spec_harness" >/dev/null
  recomputed=$(cs_pack_sha256_of "$outd/pack.md")
  persisted=$(sed -n 's/.*"pack_sha256": "\([^"]*\)".*/\1/p' "$outd/pack.json")
  [ -n "$persisted" ] || fail "$spec: pack.json has no pack_sha256 field"
  [ "$recomputed" = "$persisted" ] || fail "$spec: persisted pack_sha256 ($persisted) does not match the actual pack.md bytes ($recomputed)"
done
pass "the persisted pack hash matches the bytes actually written, for every role"

pass "cs-context-pack.sh"
