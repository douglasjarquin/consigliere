#!/usr/bin/env bash
# Behavior (portable): bin/cs-bootstrap.sh's axi-family version floors and its
# CS_BOOTSTRAP_NETWORK phase split.
#
# The phase split exists so bin/cs-session-start.sh can compose its digest from
# local reads alone while bin/cs-startup-network.sh runs the network half
# concurrently. Its whole safety argument is that the two halves are a strict
# PARTITION of the unsplit run - no step in both, none in neither - so that
# section drives all three phases against one fixture and compares the line
# multisets directly rather than trusting a reading of the source.
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
#     (unparseable), never silently accepted;
#   - a version behind a single tool-name prefix ("gh-axi 0.1.29") is comparable,
#     while a prerelease, trailing text, or prose containing a dotted token is
#     not.
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

CS_TEST_GH_AXI_VERSION="gh-axi $floor"
out=$(run_bootstrap)
assert_no_line "$out" '^MISSING: gh-axi' 'an at-floor build behind a tool-name prefix is comparable'

prefixed_under=$(cs_test_version_below "$floor") ||
  fail "no below-floor fixture is derivable from the gh-axi floor $floor"
CS_TEST_GH_AXI_VERSION="gh-axi/$prefixed_under"
out=$(run_bootstrap)
assert_line "$out" "^MISSING: gh-axi ${prefixed_under//./\\.} below floor $floor" \
  'a prefixed below-floor build fires with the version behind the prefix shown'
unset CS_TEST_GH_AXI_VERSION
pass 'one clean release, bare or behind a tool-name prefix, is comparable'

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

# --- CS_BOOTSTRAP_NETWORK: skip and only partition the unsplit run ------------
# A mutating fixture (DETECT_ONLY unset) so the sweeps are in scope too, built
# so every one of its diagnostics is deterministic and reproducible on repeat:
# a project directory that is not a git repo (fleet sync reports it and returns
# before any fetch, so nothing leaves this machine) and a malformed capo
# registry row (the capo sweep reports it and touches nothing).

PART_ROOT="$TMP/partition-root"
mkdir -p "$PART_ROOT"
git init -q -b main "$PART_ROOT"
git -C "$PART_ROOT" commit -q --allow-empty -m init

PART_HOME="$TMP/partition-home"
mkdir -p "$PART_HOME/config" "$PART_HOME/state" "$PART_HOME/data" \
  "$PART_HOME/host" "$PART_HOME/projects/plainproj"
printf -- '- broken-capo - no structured fields here\n' > "$PART_HOME/host/capos.md"

PART_FB=$(cs_fakebin "$TMP/partition-tools")
# gh must be PRESENT and unauthenticated: an absent gh is skipped by bootstrap's
# own presence guard, which would leave the network half without its probe line.
cat > "$PART_FB/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cat > "$PART_FB/herdr" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$PART_FB/gh" "$PART_FB/herdr"
for t in gh-axi tasks-axi lavish-axi quota-axi; do
  cs_fake_version_tool "$PART_FB" "$t" "CS_TEST_UNUSED_${t//-/_}_VERSION" 9.9.9
done

run_partition() {  # <all|skip|only>
  PATH="$PART_FB:$PATH" CS_HOME="$PART_HOME" CS_ROOT_OVERRIDE="$PART_ROOT" \
    CS_BOOTSTRAP_NETWORK="$1" "$BOOTSTRAP" 2>&1
}

part_all=$(run_partition all)
part_skip=$(run_partition skip)
part_only=$(run_partition only)

# Each half must actually carry work, or the partition below would hold
# vacuously for a split that silently dropped everything.
assert_contains "$part_only" 'NEEDS_GH_AUTH:' 'the network half lost the gh auth probe'
assert_contains "$part_only" 'FLEET_SYNC: plainproj: skipped: not a git repo' \
  'the network half lost the fleet sync'
assert_contains "$part_skip" 'CAPO_SYNC: skipped: malformed capo registry entry' \
  'the local half lost the capo sweep'
assert_not_contains "$part_skip" 'NEEDS_GH_AUTH:' 'the local half ran the network gh auth probe'
assert_not_contains "$part_skip" 'FLEET_SYNC:' 'the local half ran the network fleet sync'
assert_not_contains "$part_only" 'CAPO_SYNC:' 'the network half ran the local capo sweep'
assert_not_contains "$part_only" 'BOOTSTRAP_INFO:' 'the network half repeated local tool detection'

# No line in both halves.
printf '%s\n' "$part_skip" | sort -u > "$TMP/part.skip"
printf '%s\n' "$part_only" | sort -u > "$TMP/part.only"
both=$(comm -12 "$TMP/part.skip" "$TMP/part.only" | grep -v '^$' || true)
[ -z "$both" ] || fail "a check ran in BOTH phases: $both"

# Their union is exactly the unsplit run, as a multiset: nothing added, nothing
# lost, and no duplicate introduced by a step landing in both halves.
printf '%s\n%s\n' "$part_skip" "$part_only" | grep -v '^$' | sort > "$TMP/part.union"
printf '%s\n' "$part_all" | grep -v '^$' | sort > "$TMP/part.all"
diff "$TMP/part.all" "$TMP/part.union" > "$TMP/part.diff" 2>&1 \
  || fail "skip + only is not the unsplit run:"$'\n'"$(cat "$TMP/part.diff")"
pass 'CS_BOOTSTRAP_NETWORK skip and only are a strict partition of the unsplit run'

# An unrecognized value must run EVERYTHING rather than silently skipping a
# safety sweep, so a typo can never quietly disable a check.
part_typo=$(run_partition nonsense)
printf '%s\n' "$part_typo" | grep -v '^$' | sort > "$TMP/part.typo"
diff "$TMP/part.all" "$TMP/part.typo" >/dev/null 2>&1 \
  || fail "an unrecognized CS_BOOTSTRAP_NETWORK did not fall back to the full run"
pass 'an unrecognized CS_BOOTSTRAP_NETWORK falls back to the full run'

# --- CS_BOOTSTRAP_NETWORK_LOCK_PID: a stale worker never sweeps ---------------
# The deferred worker outlives the session start that launched it, so each
# network mutating sweep re-verifies that state/.lock still names the session
# that asked. A changed owner reports the skip; it never runs the sweep anyway.
printf '424242\n' > "$PART_HOME/state/.lock"
stale=$(PATH="$PART_FB:$PATH" CS_HOME="$PART_HOME" CS_ROOT_OVERRIDE="$PART_ROOT" \
  CS_BOOTSTRAP_NETWORK=only CS_BOOTSTRAP_NETWORK_LOCK_PID=999999 "$BOOTSTRAP" 2>&1)
assert_contains "$stale" 'NETWORK_CHECKS: fleet lock ownership changed before project clone refresh' \
  'a stale worker did not report the sweep it skipped'
assert_not_contains "$stale" 'FLEET_SYNC:' 'a stale worker ran a mutating sweep it no longer owned'
assert_contains "$stale" 'NEEDS_GH_AUTH:' 'the read-only probe was withheld from a stale worker'

owned=$(PATH="$PART_FB:$PATH" CS_HOME="$PART_HOME" CS_ROOT_OVERRIDE="$PART_ROOT" \
  CS_BOOTSTRAP_NETWORK=only CS_BOOTSTRAP_NETWORK_LOCK_PID=424242 "$BOOTSTRAP" 2>&1)
assert_contains "$owned" 'FLEET_SYNC: plainproj: skipped: not a git repo' \
  'a worker whose lock still names its own session was refused its sweep'
assert_not_contains "$owned" 'NETWORK_CHECKS:' \
  'an authorized worker reported an ownership change that did not happen'
rm -f "$PART_HOME/state/.lock"
pass 'a deferred worker sweeps only while state/.lock still names the session that asked'

# --- the bash floor refuses the whole bootstrap, fail closed ------------------
# Below bin/cs-doctor.sh's floor the nameref argv builders fail OPEN (empty
# argv, rc 0), so the gate must refuse (exit 1, BASH_FLOOR line) rather than
# report and continue. A pre-floor bash cannot be summoned portably, so the
# refusal machinery is driven the other way: a doctored owner whose floor no
# real bash meets, through a symlink farm so bootstrap resolves everything
# else unchanged. An owner the floor cannot be read from must refuse the same
# way - an unverified interpreter is not a verified one.
FLOORBIN="$TMP/floor-bin"
mkdir -p "$FLOORBIN"
for f in "$ROOT"/bin/*; do ln -s "$f" "$FLOORBIN/$(basename "$f")"; done
rm "$FLOORBIN/cs-doctor.sh"
printf 'BASH_FLOOR_MAJOR=99\nBASH_FLOOR_MINOR=9\n' > "$FLOORBIN/cs-doctor.sh"
rc=0
out=$(PATH="$BASE_PATH" CS_HOME="$HOME_DIR" CS_ROOT_OVERRIDE="$ROOT" \
  CS_BOOTSTRAP_DETECT_ONLY=1 "$FLOORBIN/cs-bootstrap.sh" 2>&1) || rc=$?
expect_code 1 "$rc" 'a bash below the floor must refuse the bootstrap'
assert_contains "$out" 'BASH_FLOOR:' 'the refusal carries its named blocker'
assert_contains "$out" '99.9' 'the refusal names the required floor'
assert_not_contains "$out" 'MISSING:' 'nothing after the refusal may run'

printf 'not parseable\n' > "$FLOORBIN/cs-doctor.sh"
rc=0
out=$(PATH="$BASE_PATH" CS_HOME="$HOME_DIR" CS_ROOT_OVERRIDE="$ROOT" \
  CS_BOOTSTRAP_DETECT_ONLY=1 "$FLOORBIN/cs-bootstrap.sh" 2>&1) || rc=$?
expect_code 1 "$rc" 'an unreadable floor must refuse, not assume'
assert_contains "$out" 'BASH_FLOOR:' 'the unreadable-floor refusal carries the same blocker'
pass 'the bash floor is enforced fail-closed at the bootstrap gate'

printf 'ok - cs-bootstrap axi version floors and network phase split\n'
