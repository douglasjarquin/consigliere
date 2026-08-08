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
for util in bash env awk sed grep head cat tr uname dirname basename readlink mkdir; do
  src=$(command -v "$util") || fail "test fixture needs $util on PATH"
  ln -s "$src" "$TOOLS/$util"
done
BASE_PATH="$FAKEBIN:$TOOLS"

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

# --- the axi floors: doctor gates the builds session start would refuse -------
#
# cs-deps-lib.sh owns the floors, so the preflight and the session-start gate
# cannot disagree about which installed build is out of date. Both boundaries
# are derived from the owner, never hardcoded here.

axi_floor=$(cs_deps_axi_floor gh-axi)
axi_under=$(cs_test_version_below "$axi_floor") ||
  fail "no below-floor fixture is derivable from the gh-axi floor $axi_floor"
cs_fake_version_tool "$FAKEBIN" gh-axi CS_TEST_GH_AXI_VERSION "$axi_under"
floor_out=$(PATH="$BASE_PATH" "$DOCTOR" 2>&1)
expect_code 1 "$?" 'a below-floor required axi build keeps the preflight failing'
assert_line "$floor_out" "^  MISSING +gh-axi +${axi_under//./\\.} +below the ${axi_floor//./\\.} floor" \
  'doctor reports a below-floor gh-axi as a required gap, not as ok'
assert_contains "$floor_out" 'npm i -g gh-axi' 'the floor gap carries the upgrade suggestion'

cs_fake_version_tool "$FAKEBIN" gh-axi CS_TEST_GH_AXI_VERSION "$axi_floor"
floor_out=$(PATH="$BASE_PATH" "$DOCTOR" 2>&1)
assert_line "$floor_out" "^  ok +gh-axi +${axi_floor//./\\.}" 'an at-floor gh-axi is reported ok'

quota_floor=$(cs_deps_axi_floor quota-axi)
quota_under=$(cs_test_version_below "$quota_floor") ||
  fail "no below-floor fixture is derivable from the quota-axi floor $quota_floor"
cs_fake_version_tool "$FAKEBIN" quota-axi CS_TEST_QUOTA_AXI_VERSION "$quota_under"
floor_out=$(PATH="$BASE_PATH" "$DOCTOR" 2>&1)
assert_line "$floor_out" "^  WARN +quota-axi +${quota_under//./\\.} +below the ${quota_floor//./\\.} floor" \
  'a below-floor optional axi build warns rather than failing the run'
rm -f "$FAKEBIN/gh-axi" "$FAKEBIN/quota-axi"
pass 'doctor gates the axi floors it shares with bootstrap'

# --- config section: the user-owned tree ---------------------------------------
# Migration state, symlink-target visibility, and the two loss tripwires
# (host-tier symlink-out, rename-writer sever). docs/configuration.md owns the
# inventory these checks read.

CFG_HOME="$TMP/cfg-home"
mkdir -p "$CFG_HOME/config" "$CFG_HOME/host" "$CFG_HOME/data" "$TMP/elsewhere"

cfg_doctor() { PATH="$BASE_PATH" CS_HOME="$CFG_HOME" "$DOCTOR" 2>&1; }

out=$(cfg_doctor)
assert_line "$out" 'ok +layout +- +no pre-move paths' 'a migrated home reports the layout in effect'

printf 'x\n' > "$CFG_HOME/data/boss.md"
out=$(cfg_doctor)
assert_line "$out" 'FAIL +boss.md +- +pre-move path still exists' 'a pre-move path is a failure'
assert_contains "$out" 'cs-migrate-config.sh' 'the migration failure names the migrator'
rm "$CFG_HOME/data/boss.md"

printf 'claude\n' > "$TMP/elsewhere/harness"
ln -s "$TMP/elsewhere/harness" "$CFG_HOME/host/harness.conf"
out=$(cfg_doctor)
assert_line "$out" 'FAIL +harness\.conf +- +host-tier file symlinked outside' \
  'a host-tier symlink out of the home is a failure, not a note'
rm "$CFG_HOME/host/harness.conf"

# permission-mode is a Claude ACCOUNT policy, deliberately portable: the same
# symlink arrangement that fails in host/ is fine in config/.
printf 'claude auto\n' > "$TMP/elsewhere/permission-mode"
ln -s "$TMP/elsewhere/permission-mode" "$CFG_HOME/config/permission-mode.conf"
out=$(cfg_doctor)
assert_line "$out" 'ok +permission-mode\.conf +- +symlink ->' \
  'a portable permission-mode symlink is reported, never failed'
rm "$CFG_HOME/config/permission-mode.conf"

ln -s "$TMP/elsewhere/backlog.md" "$CFG_HOME/config/backlog.md"
out=$(cfg_doctor)
assert_line "$out" 'FAIL +backlog\.md +- +symlinked, but its writer replaces it by rename' \
  'a symlinked backlog is a failure: tasks-axi severs it on the first mutation'
rm "$CFG_HOME/config/backlog.md"

printf 'x\n' > "$CFG_HOME/config/stray.txt"
out=$(cfg_doctor)
assert_line "$out" 'WARN +stray\.txt +- +not a known name for this tier' 'an unknown entry is reported by name'
rm "$CFG_HOME/config/stray.txt"

printf 'the boss\n' > "$TMP/elsewhere/boss.md"
ln -s "$TMP/elsewhere/boss.md" "$CFG_HOME/config/boss.md"
out=$(cfg_doctor)
assert_line "$out" 'ok +boss\.md +- +symlink ->' 'a portable symlink is reported with its resolved target'
rm "$CFG_HOME/config/boss.md"

pass 'the config section reports migration state, symlink targets, and the loss tripwires'

# --- telemetry is optional: off is information, malformed is a named warning --
# Telemetry can only ever stop recording, never stop a session, so nothing it
# reports may count as a required problem. docs/telemetry.md owns the contract.

out=$(cfg_doctor)
assert_line "$out" 'ok +telemetry +- +disabled \(optional; no host/telemetry\.conf\)' \
  'telemetry off is an ordinary informational line'
assert_no_line "$out" 'WARN +telemetry' 'telemetry off is never a warning'

printf 'enabled true\nretain_days 14\n' > "$CFG_HOME/host/telemetry.conf"
out=$(cfg_doctor)
assert_line "$out" 'WARN +telemetry +- +enabled but jq is missing' \
  'telemetry is honest that it records nothing without jq'

# With jq present the same config reports where it is recording.
cs_fake_exit0 "$FAKEBIN" jq
out=$(cfg_doctor)
assert_line "$out" 'ok +telemetry +14d +recording to .*/data/telemetry/turns\.jsonl' \
  'enabled telemetry reports its retention and its resolved storage path'
assert_no_line "$out" 'WARN +telemetry\.conf +- +not a known name' \
  'telemetry.conf is a known host-tier name, not a stray'

printf 'enabled maybe\n' > "$CFG_HOME/host/telemetry.conf"
out=$(cfg_doctor)
assert_line "$out" 'WARN +telemetry +- +host/telemetry\.conf is enabled must be true or false' \
  'a malformed telemetry config is reported specifically'
assert_contains "$out" 'docs/telemetry.md' 'the malformed telemetry warning names its owner doc'

# A malformed OPTIONAL config must not change the verdict. The verdict is the
# doctor's exit status plus its closing line, and that line CARRIES the count
# ("1 required problem" / "N required problems" / "Ready:"), so comparing the
# line text and the status detects a config that silently added a problem.
verdict() { # -> "<exit-status> <closing verdict line>"
  local out rc line
  out=$(cfg_doctor); rc=$?
  line=$(printf '%s\n' "$out" | grep -E 'required problem|^Ready:' | head -1)
  printf '%s %s\n' "$rc" "$line"
}

malformed_verdict=$(verdict)
rm -f "$CFG_HOME/host/telemetry.conf"
clean_verdict=$(verdict)
[ "$malformed_verdict" = "$clean_verdict" ] ||
  fail "a malformed telemetry config must not change the doctor verdict: '$malformed_verdict' vs '$clean_verdict'"

# The guard must be able to FAIL, or it proves nothing. A genuine required
# problem moves both the status and the count, so the same comparison rejects it.
printf 'x\n' > "$CFG_HOME/data/boss.md"
broken_verdict=$(verdict)
rm -f "$CFG_HOME/data/boss.md"
[ "$broken_verdict" != "$clean_verdict" ] ||
  fail "the verdict guard cannot detect a real required problem, so it proves nothing: '$broken_verdict'"
[ "$(verdict)" = "$clean_verdict" ] || fail 'removing the induced problem must restore the verdict'
pass 'telemetry is reported as optional: disabled informs, enabled names its path, malformed warns'

pass 'cs-doctor behaviors'
