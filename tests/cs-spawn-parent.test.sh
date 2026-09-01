#!/usr/bin/env bash
set -u
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/cs-meta-lib.sh
. "$ROOT/bin/cs-meta-lib.sh"

if ! declare -F cs_meta_validate_parent_edge >/dev/null 2>&1; then
  fail "metadata must expose parent-edge validation"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cs-spawn-parent.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
cat > "$HOME_DIR/state/child.meta" <<EOF
task_id=child
home=$HOME_DIR
pane=w-child:p1
parent_task_id=parent
parent_home=$HOME_DIR
parent_state=$HOME_DIR/state
parent_pane=w1:p1
parent_generation=parent-generation-1
endpoint_generation=child-generation-1
EOF

cs_meta_validate_parent_edge "$HOME_DIR/state/child.meta" || fail "valid parent edge should pass"
pass "metadata accepts an exact immediate-parent edge"

cp "$HOME_DIR/state/child.meta" "$HOME_DIR/state/missing.meta"
sed -i.bak 's#parent_home=.*#parent_home=/missing/parent#' "$HOME_DIR/state/missing.meta"
rm -f "$HOME_DIR/state/missing.meta.bak"
if cs_meta_validate_parent_edge "$HOME_DIR/state/missing.meta" >/dev/null 2>&1; then
  fail "missing parent home must be refused"
fi
pass "missing parent home is refused"

cp "$HOME_DIR/state/child.meta" "$HOME_DIR/state/stale.meta"
sed -i.bak 's/parent_generation=.*/parent_generation=/' "$HOME_DIR/state/stale.meta"
rm -f "$HOME_DIR/state/stale.meta.bak"
if cs_meta_validate_parent_edge "$HOME_DIR/state/stale.meta" >/dev/null 2>&1; then
  fail "missing parent generation must be refused"
fi
pass "missing parent generation is refused"

pass "parent-edge metadata contract"
