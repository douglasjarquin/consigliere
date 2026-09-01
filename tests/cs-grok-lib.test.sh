#!/usr/bin/env bash
# Behavior (portable): cs-grok-lib.sh - binary resolution, turn-end hook auth.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/cs-grok-lib.sh
. "$ROOT/bin/cs-grok-lib.sh"

TMP=$(cs_test_tmproot cs-grok-lib)
GROK_HOME="$TMP/grok-home"
export GROK_HOME
mkdir -p "$GROK_HOME/hooks"

FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/grok" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --help) printf 'Grok Build TUI\nUsage: grok [OPTIONS]\n'; exit 0 ;;
  --version) printf 'grok 9.9.9 (test) [stable]\n'; exit 0 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/grok"
ln -sf grok "$FAKEBIN/agent"

resolved=$(PATH="$FAKEBIN:$PATH" cs_grok_resolve_binary)
[ "$resolved" = "$FAKEBIN/grok" ] || fail "resolve must prefer verified grok on PATH (got $resolved)"

badbin="$TMP/badbin"
mkdir -p "$badbin"
cat > "$badbin/agent" <<'SH'
#!/usr/bin/env bash
printf 'not grok\n'
SH
chmod +x "$badbin/agent"
if PATH="$badbin" GROK_HOME="$TMP/empty-grok-home" cs_grok_resolve_binary 2>/dev/null; then
  fail "unverified agent must be rejected"
fi
pass "cs_grok_resolve_binary verifies grok and rejects impostor agent"

turnend="$TMP/state/t1.turn-ended"
state="$TMP/state"
wt="$TMP/wt"
mkdir -p "$state" "$wt"
cs_grok_turnend_arm "$turnend" "$state" t1 "$wt" || fail "turnend arm failed"
assert_present "$GROK_HOME/hooks/cs-turn-end.sh" "global hook script must exist"
assert_present "$GROK_HOME/hooks/cs-turn-end.json" "global hook json must exist"
assert_present "$wt/.cs-grok-turnend" "worktree pointer must exist"
case "$(cat "$wt/.cs-grok-turnend")" in
  token=cs.*) ;;
  *) fail "pointer must carry cs. token" ;;
esac
assert_present "$state/t1.grok-turnend-token" "state token file must exist"
token=$(cat "$state/t1.grok-turnend-token")
assert_present "$GROK_HOME/hooks/cs-turn-end.d/$token" "registry entry must exist"
[ "$(cat "$GROK_HOME/hooks/cs-turn-end.d/$token")" = "$turnend" ] ||
  fail "registry must map token to turn-end path"

GROK_WORKSPACE_ROOT="$wt" bash "$GROK_HOME/hooks/cs-turn-end.sh"
assert_present "$turnend" "registered hook must touch turn-end"

evil="$TMP/evil"
mkdir -p "$evil"
printf 'token=cs.evil0000000\n' > "$evil/.cs-grok-turnend"
rm -f "$turnend"
GROK_WORKSPACE_ROOT="$evil" bash "$GROK_HOME/hooks/cs-turn-end.sh"
assert_absent "$turnend" "hook must ignore unregistered token"

printf 'token=%s\n' "$token" > "$wt/.cs-grok-turnend"
GROK_WORKSPACE_ROOT="$wt" bash "$GROK_HOME/hooks/cs-turn-end.sh"
assert_present "$turnend" "registered hook must touch again after restore"

cs_grok_turnend_disarm "$state" t1 "$wt"
assert_absent "$wt/.cs-grok-turnend" "disarm removes pointer"
assert_absent "$state/t1.grok-turnend-token" "disarm removes state token"
assert_absent "$GROK_HOME/hooks/cs-turn-end.d/$token" "disarm removes registry entry"
pass "grok turn-end arm/disarm round trip"

pass "cs-grok-lib behavior"
