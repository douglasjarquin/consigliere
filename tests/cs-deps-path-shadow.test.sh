#!/usr/bin/env bash
# cs_deps_path_hits and cs_deps_path_shadow_gap detect a newer copy later on PATH.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(cs_test_tmproot cs-deps-path-shadow)
FAKEBIN="$TMP/bin"
TOOL=cs-shadow-probe-tool
mkdir -p "$FAKEBIN/old" "$FAKEBIN/new"
export PATH="$FAKEBIN/old:$FAKEBIN/new:/usr/bin:/bin"

cat > "$FAKEBIN/old/$TOOL" <<'SH'
#!/usr/bin/env bash
echo "cs-shadow-probe-tool 1.0.0"
SH
cat > "$FAKEBIN/new/$TOOL" <<'SH'
#!/usr/bin/env bash
echo "cs-shadow-probe-tool 2.0.0"
SH
chmod +x "$FAKEBIN/old/$TOOL" "$FAKEBIN/new/$TOOL"

# shellcheck source=bin/cs-deps-lib.sh
. "$ROOT/bin/cs-deps-lib.sh"

hits=$(cs_deps_path_hits "$TOOL")
assert_contains "$hits" "$FAKEBIN/old/$TOOL" "path_hits finds the first-resolved copy"
assert_contains "$hits" "$FAKEBIN/new/$TOOL" "path_hits finds the later copy"

if shadow=$(cs_deps_path_shadow_gap "$TOOL"); then
  IFS=$'\t' read -r rpath rver bpath bver <<< "$shadow"
  assert_contains "$rpath" "$FAKEBIN/old/$TOOL" "shadow names the resolved path"
  assert_contains "$bpath" "$FAKEBIN/new/$TOOL" "shadow names the newer path"
  assert_contains "$rver" 1.0.0 "shadow records the older version"
  assert_contains "$bver" 2.0.0 "shadow records the newer version"
else
  fail "expected PATH shadow between old and new copies"
fi

export PATH="$FAKEBIN/new:/usr/bin:/bin"
if cs_deps_path_shadow_gap "$TOOL" >/dev/null 2>&1; then
  fail "no shadow when PATH already resolves the newest copy"
fi

printf 'all cs-deps-path-shadow tests passed\n'
