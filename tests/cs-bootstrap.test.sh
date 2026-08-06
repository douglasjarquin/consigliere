#!/usr/bin/env bash
# Behavior (portable): bin/cs-bootstrap.sh's axi-family version floors.
#
# Bootstrap owns the axi-family floors and their bump policy (see its header).
# These tests pin the enforcement behavior, not the floor values: each floor is
# read from the script itself, and the below-floor fixture is derived as the
# patch immediately below it, so the boundary stays genuine across deliberate
# floor bumps without this file naming a version that drifts.
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

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data"

FAKEBIN=$(cs_fakebin "$TMP")
cs_fake_version_tool "$FAKEBIN" gh-axi CS_TEST_GH_AXI_VERSION 9.9.9
cs_fake_version_tool "$FAKEBIN" tasks-axi CS_TEST_TASKS_AXI_VERSION 9.9.9
cs_fake_version_tool "$FAKEBIN" lavish-axi CS_TEST_LAVISH_AXI_VERSION 9.9.9
cs_fake_version_tool "$FAKEBIN" quota-axi CS_TEST_QUOTA_AXI_VERSION 9.9.9

# floor_of <CONSTANT-STEM> - the floor value the script itself declares.
floor_of() {
  sed -n "s/^CS_${1}_MIN=\([0-9.]*\).*/\1/p" "$BOOTSTRAP"
}

# below <version> - the patch immediately below <version>, so the boundary test
# is genuine rather than merely "some old version".
below() {
  printf '%s\n' "$1" | awk -F. -v OFS=. '{
    if ($NF == 0) exit 1
    $NF = $NF - 1
    print
  }'
}

run_bootstrap() {
  PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" CS_ROOT_OVERRIDE="$ROOT" \
    CS_BOOTSTRAP_DETECT_ONLY=1 "$BOOTSTRAP" 2>&1
}

assert_line() {
  printf '%s\n' "$1" | grep -Eq -- "$2" ||
    fail "$3 (no line matching /$2/)"$'\n'"--- output ---"$'\n'"$1"
}

assert_no_line() {
  printf '%s\n' "$1" | grep -Eq -- "$2" &&
    fail "$3 (unexpected line matching /$2/)"$'\n'"--- output ---"$'\n'"$1"
  return 0
}

# --- gh-axi (required): below fires MISSING, at-floor is silent ----------------

floor=$(floor_of GH_AXI)
export CS_TEST_GH_AXI_VERSION
CS_TEST_GH_AXI_VERSION=$(below "$floor")
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
  local tool=$1 var=$2 stem=$3 floor out
  floor=$(floor_of "$stem")
  export "$var=$(below "$floor")"
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

check_optional_floor tasks-axi CS_TEST_TASKS_AXI_VERSION TASKS_AXI
check_optional_floor lavish-axi CS_TEST_LAVISH_AXI_VERSION LAVISH_AXI
check_optional_floor quota-axi CS_TEST_QUOTA_AXI_VERSION QUOTA_AXI

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

floor=$(floor_of GH_AXI)
export CS_TEST_GH_AXI_VERSION
CS_TEST_GH_AXI_VERSION='requires Node 99.0'
out=$(run_bootstrap)
assert_line "$out" "^MISSING: gh-axi .*below floor $floor" \
  'a dotted token inside arbitrary version text stays below-floor'

CS_TEST_GH_AXI_VERSION="${floor}-rc.1"
out=$(run_bootstrap)
assert_line "$out" "^MISSING: gh-axi .*below floor $floor" \
  'a prerelease at the stable floor stays below-floor'
unset CS_TEST_GH_AXI_VERSION
pass 'only complete dotted release versions are comparable'

# --- a healthy fleet of fake tools keeps bootstrap silent about floors ---------

out=$(run_bootstrap)
assert_no_line "$out" 'below floor' 'default 9.9.9 fakes sit above every floor'
pass 'a version-reporting fake suite is never reported as out of date'

printf 'ok - cs-bootstrap axi version floors\n'
