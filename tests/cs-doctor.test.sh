#!/usr/bin/env bash
# Behavior: cs-doctor.sh reports dependency state without ever installing, and
# fails only on required gaps. Also proves the inventory in cs-deps-lib.sh is the
# single owner both cs-doctor.sh and cs-bootstrap.sh read, so a missing tool
# cannot be reported by one and silently ignored by the other.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DOCTOR="$ROOT/bin/cs-doctor.sh"
BOOTSTRAP="$ROOT/bin/cs-bootstrap.sh"

TMP=$(cs_test_tmproot cs-doctor)
FAKEBIN=$(cs_fakebin "$TMP")

# A hermetic PATH. The scripts need a handful of ordinary utilities, so those are
# symlinked into their own dir; every consigliere dependency is then explicitly
# present or absent in the fixture, never inherited from the developer's machine
# (a stock macOS /usr/bin already ships git, python3, and sometimes jq).
TOOLS="$TMP/tools"
mkdir -p "$TOOLS"
for util in bash env awk sed grep head cat tr uname dirname basename; do
  src=$(command -v "$util") || fail "test fixture needs $util on PATH"
  ln -s "$src" "$TOOLS/$util"
done
BASE_PATH="$FAKEBIN:$TOOLS"

# assert_line <output> <extended-regex> <label>
assert_line() {
  printf '%s\n' "$1" | grep -Eq -- "$2" ||
    fail "$3 (no line matching /$2/)"$'\n'"--- output ---"$'\n'"$1"
}

# --- --help never runs a check and never mutates ------------------------------

help_out=$(PATH="$BASE_PATH" "$DOCTOR" --help 2>&1)
expect_code 0 "$?" '--help exits 0'
assert_contains "$help_out" 'CHECKS ONLY' '--help states the checks-only contract'
assert_not_contains "$help_out" 'set -u' '--help stops at the end of the header block'

PATH="$BASE_PATH" "$DOCTOR" --bogus >/dev/null 2>&1
expect_code 2 "$?" 'an unknown argument exits 2'
pass '--help and argument validation'

# --- a bare machine: every required dependency missing ------------------------

bare_out=$(PATH="$BASE_PATH" "$DOCTOR" 2>&1)
expect_code 1 "$?" 'missing required dependencies exit 1'
for tool in herdr codex jq gh gh-axi git; do
  assert_line "$bare_out" "^  MISSING +$tool +-" "bare machine reports $tool missing"
done
assert_contains "$bare_out" 'npm i -g gh-axi' 'a missing tool carries an install suggestion'
assert_contains "$bare_out" 'installs nothing' 'the verdict repeats that nothing was installed'
assert_line "$bare_out" '^  SKIP +herdr server' 'the server check skips, not fails, when herdr is absent'
assert_line "$bare_out" '^  SKIP +gh auth' 'the auth check skips, not fails, when gh is absent'
assert_line "$bare_out" '^6 required problems' 'the verdict counts every required gap'
pass 'bare machine: required gaps fail with suggestions, dependent checks skip'

# --- optional and contributor gaps never fail --------------------------------

assert_line "$bare_out" '^  absent +tasks-axi' 'an absent optional tool reports absent, not MISSING'
assert_line "$bare_out" '^  absent +shellcheck' 'an absent contributor tool reports absent'
pass 'optional and contributor gaps are reported without failing'

# --- gh present but not authenticated is a required failure -------------------

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --version) echo 'gh version 9.9.9 (2026-01-01)' ;;
  auth) exit 1 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/gh"

auth_out=$(PATH="$BASE_PATH" "$DOCTOR" 2>&1)
expect_code 1 "$?" 'an unauthenticated gh still exits 1'
assert_line "$auth_out" '^  ok +gh +9\.9\.9' 'the version column comes from the tool itself'
assert_line "$auth_out" '^  MISSING +gh auth' 'gh present but not logged in is a required failure'
assert_contains "$auth_out" 'gh auth login' 'the auth gap suggests the login command'
pass 'a present-but-unusable tool fails the service check, not the tool check'

# --- one inventory: doctor and bootstrap agree on the same bare machine -------

boot_out=$(PATH="$BASE_PATH" CS_BOOTSTRAP_DETECT_ONLY=1 CS_HOME="$TMP/home" "$BOOTSTRAP" 2>&1)
assert_line "$boot_out" '^MISSING:.*herdr' 'bootstrap reports the shared required inventory'
for tool in codex jq gh-axi git; do
  assert_line "$boot_out" "^MISSING:.* $tool( |\$)" "bootstrap reports $tool from the shared inventory"
done
assert_contains "$boot_out" 'BOOTSTRAP_INFO: optional tool tasks-axi' 'bootstrap keeps its optional-tool line'
assert_not_contains "$boot_out" 'shellcheck' 'the contributor class stays out of session-start output'
pass 'cs-bootstrap.sh and cs-doctor.sh read one shared inventory'

# --- the inventory itself -----------------------------------------------------

# shellcheck source=bin/cs-deps-lib.sh
. "$ROOT/bin/cs-deps-lib.sh"

CS_HARNESS_OVERRIDE=claude
required=$(cs_deps_tools required)
optional=$(cs_deps_tools optional)
assert_contains "$required" 'claude' 'a claude root session requires claude'
assert_not_contains "$required" 'codex' 'a claude root session does not require codex'
assert_contains "$optional" 'codex' 'the other harness is optional'
CS_HARNESS_OVERRIDE=codex

cs_deps_tools bogus >/dev/null 2>&1
expect_code 1 "$?" 'an unknown class is rejected'

for tool in $(cs_deps_tools required) $(cs_deps_tools optional) claude \
  $(cs_deps_tools contributor); do
  cs_deps_purpose "$tool" >/dev/null || fail "no purpose recorded for $tool"
  cs_deps_hint "$tool" >/dev/null || fail "no install suggestion recorded for $tool"
done
pass 'every inventory tool has a purpose and an install suggestion'

assert_contains "$(cs_deps_hint no-mistakes)" \
  'https://github.com/kunchenguid/no-mistakes' \
  'the no-mistakes install suggestion names its repository'

pass 'cs-doctor behaviors'
