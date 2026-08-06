#!/usr/bin/env bash
# Behavior: cs-project-mode.sh resolves delivery mode + yolo from
# config/projects.md, defaulting to "no-mistakes off" on missing registry,
# unknown project, or unknown mode - a typo never silently drops the gate.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(cs_test_tmproot cs-project-mode)
export CS_DATA_OVERRIDE="$TMP/data"
export CS_CONFIG_OVERRIDE="$TMP/config"
mkdir -p "$TMP/data" "$TMP/config"

BIN="$ROOT/bin/cs-project-mode.sh"

out=$("$BIN" ghost 2>/dev/null)
[ "$out" = "no-mistakes off" ] || fail "missing registry defaults: got '$out'"
pass "missing registry defaults to no-mistakes off"

cat > "$TMP/config/projects.md" <<'EOF'
# Projects
- alpha - plain default project (added 2026-07-01)
- beta [direct-PR] - direct PR project (added 2026-07-01)
- gamma [local-only +yolo] - local yolo project (added 2026-07-01)
- delta [bogus-mode] - typo mode project (added 2026-07-01)
- epsilon [no-mistakes +yolo] - gated but autonomous (added 2026-07-01)
EOF

check() {
  local name=$1 want=$2 got
  got=$("$BIN" "$name" 2>/dev/null)
  [ "$got" = "$want" ] || fail "$name: want '$want', got '$got'"
}

check alpha "no-mistakes off"
check beta "direct-PR off"
check gamma "local-only on"
check epsilon "no-mistakes on"
pass "registered modes and +yolo parse"

check delta "no-mistakes off"
check ghost "no-mistakes off"
pass "unknown mode and unknown project fall back to no-mistakes off"

pass "cs-project-mode behaviors"
