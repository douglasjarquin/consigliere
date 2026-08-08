#!/usr/bin/env bash
# Behavior (portable): bin/cs-bootstrap.sh's axi-family version floors.
#
# bin/cs-deps-lib.sh owns the axi-family floors and their bump policy; bootstrap
# is the session-start gate that enforces them. These tests pin the enforcement
# behavior, not the floor values: each floor is asked of its owner through
# cs_deps_axi_floor, and the below-floor fixture is derived from it, so the
# boundary stays genuine across deliberate floor bumps without this file naming
# a version that drifts.
#
# Pinned behavior, per gated tool:
#   - an installed build one patch below the floor fires the same diagnostic
#     path as an absent tool (MISSING for required gh-axi, BOOTSTRAP_INFO for
#     the optional tools), asking for an upgrade;
#   - a build exactly at the floor is silent;
#   - a build that answers --version with nothing is reported as below-floor
#     (unparseable), never silently accepted.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(cs_test_tmproot cs-bootstrap)
mkdir -p "$TMP"
BOOTSTRAP="$ROOT/bin/cs-bootstrap.sh"
# The floors are asked of their owner, never parsed out of a script's source.
# shellcheck source=bin/cs-deps-lib.sh
. "$ROOT/bin/cs-deps-lib.sh"

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data"

FAKEBIN=$(cs_fakebin "$TMP")
cs_fake_version_tool "$FAKEBIN" gh-axi CS_TEST_GH_AXI_VERSION 9.9.9
cs_fake_version_tool "$FAKEBIN" tasks-axi CS_TEST_TASKS_AXI_VERSION 9.9.9
cs_fake_version_tool "$FAKEBIN" lavish-axi CS_TEST_LAVISH_AXI_VERSION 9.9.9
cs_fake_version_tool "$FAKEBIN" quota-axi CS_TEST_QUOTA_AXI_VERSION 9.9.9

# A hermetic PATH. Only the four gated axi stubs and the ordinary utilities
# bootstrap itself needs are reachable, so the fixture never executes the
# developer's real gh, herdr, jq, or git - no network call, no live herdr
# server, and no dependence on what happens to be installed.
TOOLS="$TMP/tools"
mkdir -p "$TOOLS"
for util in bash env awk sed grep head cat tr uname dirname basename readlink mkdir; do
  src=$(command -v "$util") || fail "test fixture needs $util on PATH"
  ln -s "$src" "$TOOLS/$util"
done
BASE_PATH="$FAKEBIN:$TOOLS"

run_bootstrap() {
  PATH="$BASE_PATH" CS_HOME="$HOME_DIR" CS_ROOT_OVERRIDE="$ROOT" \
    CS_BOOTSTRAP_DETECT_ONLY=1 "$BOOTSTRAP" 2>&1
}

# --- gh-axi (required): below fires MISSING, at-floor is silent ----------------

floor=$(cs_deps_axi_floor gh-axi)
export CS_TEST_GH_AXI_VERSION
CS_TEST_GH_AXI_VERSION=$(cs_test_version_below "$floor") ||
  fail "no below-floor fixture is derivable from the gh-axi floor $floor"
out=$(run_bootstrap)
assert_line "$out" "^MISSING: gh-axi .*below floor $floor" 'a below-floor gh-axi reports MISSING like an absent tool'
assert_line "$out" '^MISSING: gh-axi .*upgrade' 'the gh-axi diagnostic asks for an upgrade'

CS_TEST_GH_AXI_VERSION=$floor
out=$(run_bootstrap)
assert_no_line "$out" '^MISSING: gh-axi' 'an at-floor gh-axi is silent'
unset CS_TEST_GH_AXI_VERSION
pass 'gh-axi floor: below fires, at-floor is silent'

# --- optional axi tools: below fires BOOTSTRAP_INFO, at-floor is silent --------

check_optional_floor() {
  local tool=$1 var=$2 floor under out
  floor=$(cs_deps_axi_floor "$tool")
  under=$(cs_test_version_below "$floor") ||
    fail "no below-floor fixture is derivable from the $tool floor $floor"
  export "$var=$under"
  out=$(run_bootstrap)
  assert_line "$out" "^BOOTSTRAP_INFO: optional tool $tool .*below floor $floor" \
    "a below-floor $tool reports through the optional-tool line"
  assert_line "$out" "^BOOTSTRAP_INFO: optional tool $tool .*upgrade" \
    "the $tool diagnostic asks for an upgrade"
  export "$var=$floor"
  out=$(run_bootstrap)
  assert_no_line "$out" "BOOTSTRAP_INFO: optional tool $tool" "an at-floor $tool is silent"
  unset "$var"
  pass "$tool floor: below fires, at-floor is silent"
}

check_optional_floor tasks-axi CS_TEST_TASKS_AXI_VERSION
check_optional_floor lavish-axi CS_TEST_LAVISH_AXI_VERSION
check_optional_floor quota-axi CS_TEST_QUOTA_AXI_VERSION

check_unparseable() {
  local tool=$1 var=$2 diagnostic_prefix=$3 out
  cs_fake_exit0 "$FAKEBIN" "$tool"
  out=$(run_bootstrap)
  assert_line "$out" "^${diagnostic_prefix}${tool} unparseable version below floor" \
    "a bare exit-0 $tool is reported as an unparseable below-floor build"
  cs_fake_version_tool "$FAKEBIN" "$tool" "$var" 9.9.9
  pass "$tool unparseable build: diagnostic fires"
}

check_unparseable gh-axi CS_TEST_GH_AXI_VERSION 'MISSING: '
check_unparseable tasks-axi CS_TEST_TASKS_AXI_VERSION 'BOOTSTRAP_INFO: optional tool '
check_unparseable lavish-axi CS_TEST_LAVISH_AXI_VERSION 'BOOTSTRAP_INFO: optional tool '
check_unparseable quota-axi CS_TEST_QUOTA_AXI_VERSION 'BOOTSTRAP_INFO: optional tool '

floor=$(cs_deps_axi_floor gh-axi)
export CS_TEST_GH_AXI_VERSION
CS_TEST_GH_AXI_VERSION='requires Node 99.0'
out=$(run_bootstrap)
assert_line "$out" "^MISSING: gh-axi unparseable version below floor $floor" \
  'a dotted token inside arbitrary version text stays below-floor and unparseable'

CS_TEST_GH_AXI_VERSION="${floor}-rc.1"
out=$(run_bootstrap)
assert_line "$out" "^MISSING: gh-axi unparseable version below floor $floor" \
  'a prerelease at the stable floor stays below-floor and unparseable'
assert_no_line "$out" "^MISSING: gh-axi $floor below floor $floor" \
  'the diagnostic never re-extracts a dotted token the comparator rejected'
unset CS_TEST_GH_AXI_VERSION
pass 'only complete dotted release versions are comparable'

# A tool that prints a clean above-floor number but exits nonzero is rejected by
# the comparator; the diagnostic must say so instead of naming that number.

cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '99.9.9\n'
exit 3
SH
chmod +x "$FAKEBIN/gh-axi"
out=$(run_bootstrap)
assert_line "$out" "^MISSING: gh-axi unparseable version below floor $floor" \
  'a --version that exits nonzero is reported as unparseable'
assert_no_line "$out" '^MISSING: gh-axi 99\.9\.9 below floor' \
  'the diagnostic never names a version above the floor it says the build is below'
cs_fake_version_tool "$FAKEBIN" gh-axi CS_TEST_GH_AXI_VERSION 9.9.9
pass 'a failing --version never reports as an above-floor number'

# --- an absent gated tool is absent, never "out of date" -----------------------

check_absent() {
  local tool=$1 var=$2 pattern=$3 out
  rm -f "$FAKEBIN/$tool"
  out=$(run_bootstrap)
  assert_line "$out" "$pattern" "an absent $tool is reported as absent"
  assert_no_line "$out" "$tool .*below floor" "an absent $tool never reports a version gap"
  cs_fake_version_tool "$FAKEBIN" "$tool" "$var" 9.9.9
  pass "$tool absent: reported as absent, not as an out-of-date build"
}

check_absent gh-axi CS_TEST_GH_AXI_VERSION '^MISSING:.* gh-axi'
check_absent quota-axi CS_TEST_QUOTA_AXI_VERSION '^BOOTSTRAP_INFO: optional tool quota-axi not installed'

# --- a healthy fleet of fake tools keeps bootstrap silent about floors ---------

out=$(run_bootstrap)
assert_no_line "$out" 'below floor' 'default 9.9.9 fakes sit above every floor'
pass 'a version-reporting fake suite is never reported as out of date'

printf 'ok - cs-bootstrap axi version floors\n'
