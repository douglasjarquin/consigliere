#!/usr/bin/env bash
# Behavior (portable): cs-root-lib.sh - the single owner of CS_ROOT/CS_HOME/
# DATA/STATE/CONFIG resolution. Proves cs_resolve_root reproduces the inline
# override precedence byte-for-byte across every override combination, and
# preserves the CS_HOME -> CS_ROOT_OVERRIDE fallback quirk.
#
# Every resolution seam uses ${VAR:-default} (colon-minus), so an empty value is
# equivalent to an unset one. The cases therefore drive the five override seams
# by env-prefixing the resolve call (the empty string means "absent"), which
# keeps the assignments out of any subshell body.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/cs-root-lib.sh
. "$ROOT/bin/cs-root-lib.sh"

# REPO_ROOT is what the library computes from its own location (bin/..). The lib
# lives in $ROOT/bin, so this must equal $ROOT.
REPO_ROOT=$(cd "$ROOT/bin/.." && pwd)

# lib_resolve - run the library resolver and print the five resolved values, one
# per line. Callers env-prefix the override seams.
lib_resolve() {
  cs_resolve_root
  printf '%s\n%s\n%s\n%s\n%s\n' "$CS_ROOT" "$CS_HOME" "$DATA" "$STATE" "$CONFIG"
}

# ref_resolve - the exact inline code the ~28 scripts used, with a fixed
# SCRIPT_DIR pointing at the real bin/. Its output is the pure-extraction
# contract cs_resolve_root must match.
ref_resolve() {
  local SCRIPT_DIR="$ROOT/bin" R_ROOT R_HOME R_DATA R_STATE R_CONFIG
  R_ROOT="${CS_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
  R_HOME="${CS_HOME:-${CS_ROOT_OVERRIDE:-$R_ROOT}}"
  R_DATA="${CS_DATA_OVERRIDE:-$R_HOME/data}"
  R_STATE="${CS_STATE_OVERRIDE:-$R_HOME/state}"
  R_CONFIG="${CS_CONFIG_OVERRIDE:-$R_HOME/config}"
  printf '%s\n%s\n%s\n%s\n%s\n' "$R_ROOT" "$R_HOME" "$R_DATA" "$R_STATE" "$R_CONFIG"
}

# read the five lines of a resolver's output into g_root/g_home/g_data/g_state/
# g_config for per-value assertions.
read_resolved() {
  { read -r g_root; read -r g_home; read -r g_data; read -r g_state; read -r g_config; } <<EOF
$1
EOF
}

# --- no overrides: everything derives from the lib's own location -----------
out=$(CS_ROOT_OVERRIDE='' CS_HOME='' CS_DATA_OVERRIDE='' CS_STATE_OVERRIDE='' CS_CONFIG_OVERRIDE='' lib_resolve)
read_resolved "$out"
[ "$g_root" = "$REPO_ROOT" ]          || fail "no-override CS_ROOT: expected $REPO_ROOT, got $g_root"
[ "$g_home" = "$REPO_ROOT" ]          || fail "no-override CS_HOME: expected $REPO_ROOT, got $g_home"
[ "$g_data" = "$REPO_ROOT/data" ]     || fail "no-override DATA: got $g_data"
[ "$g_state" = "$REPO_ROOT/state" ]   || fail "no-override STATE: got $g_state"
[ "$g_config" = "$REPO_ROOT/config" ] || fail "no-override CONFIG: got $g_config"
pass "no overrides: root/home/data/state/config resolve from the lib's own location"

# --- CS_ROOT_OVERRIDE wins for CS_ROOT and (quirk) for CS_HOME when CS_HOME unset
out=$(CS_ROOT_OVERRIDE=/tmp/cs-override-root CS_HOME='' CS_DATA_OVERRIDE='' CS_STATE_OVERRIDE='' CS_CONFIG_OVERRIDE='' lib_resolve)
read_resolved "$out"
[ "$g_root" = /tmp/cs-override-root ]         || fail "CS_ROOT_OVERRIDE must win for CS_ROOT (got $g_root)"
[ "$g_home" = /tmp/cs-override-root ]         || fail "quirk: CS_ROOT_OVERRIDE must win for CS_HOME when CS_HOME unset (got $g_home)"
[ "$g_data" = /tmp/cs-override-root/data ]    || fail "DATA from override root (got $g_data)"
[ "$g_state" = /tmp/cs-override-root/state ]  || fail "STATE from override root (got $g_state)"
[ "$g_config" = /tmp/cs-override-root/config ] || fail "CONFIG from override root (got $g_config)"
pass "CS_ROOT_OVERRIDE wins for CS_ROOT and CS_HOME (fallback quirk preserved)"

# --- CS_HOME (when set) wins over CS_ROOT_OVERRIDE for CS_HOME ---------------
out=$(CS_ROOT_OVERRIDE=/tmp/cs-override-root CS_HOME=/tmp/cs-explicit-home CS_DATA_OVERRIDE='' CS_STATE_OVERRIDE='' CS_CONFIG_OVERRIDE='' lib_resolve)
read_resolved "$out"
[ "$g_root" = /tmp/cs-override-root ]         || fail "CS_ROOT still from override (got $g_root)"
[ "$g_home" = /tmp/cs-explicit-home ]         || fail "explicit CS_HOME must win (got $g_home)"
[ "$g_data" = /tmp/cs-explicit-home/data ]    || fail "DATA follows CS_HOME (got $g_data)"
[ "$g_state" = /tmp/cs-explicit-home/state ]  || fail "STATE follows CS_HOME (got $g_state)"
[ "$g_config" = /tmp/cs-explicit-home/config ] || fail "CONFIG follows CS_HOME (got $g_config)"
pass "explicit CS_HOME wins over CS_ROOT_OVERRIDE for CS_HOME; data/state/config follow CS_HOME"

# --- DATA/STATE/CONFIG overrides are independent of CS_HOME ------------------
out=$(CS_ROOT_OVERRIDE='' CS_HOME=/tmp/cs-explicit-home CS_DATA_OVERRIDE=/tmp/d CS_STATE_OVERRIDE=/tmp/s CS_CONFIG_OVERRIDE=/tmp/c lib_resolve)
read_resolved "$out"
[ "$g_data" = /tmp/d ]                 || fail "CS_DATA_OVERRIDE must win (got $g_data)"
[ "$g_state" = /tmp/s ]                || fail "CS_STATE_OVERRIDE must win (got $g_state)"
[ "$g_config" = /tmp/c ]               || fail "CS_CONFIG_OVERRIDE must win (got $g_config)"
[ "$g_home" = /tmp/cs-explicit-home ]  || fail "CS_HOME unaffected by data/state/config overrides (got $g_home)"
pass "CS_DATA_OVERRIDE/CS_STATE_OVERRIDE/CS_CONFIG_OVERRIDE win independently"

# --- full parity: every override combination matches the inline reference ----
# Five override seams, each present/absent -> 32 combinations. For each, run the
# inline reference resolver and cs_resolve_root in the same environment and
# require byte-identical output. This is the direct proof the extraction changed
# no resolved value.
mismatch=0
for mask in $(seq 0 31); do
  r=""; h=""; d=""; s=""; c=""
  (( mask & 1 ))  && r=/tmp/m-root
  (( mask & 2 ))  && h=/tmp/m-home
  (( mask & 4 ))  && d=/tmp/m-data
  (( mask & 8 ))  && s=/tmp/m-state
  (( mask & 16 )) && c=/tmp/m-config
  libout=$(CS_ROOT_OVERRIDE="$r" CS_HOME="$h" CS_DATA_OVERRIDE="$d" CS_STATE_OVERRIDE="$s" CS_CONFIG_OVERRIDE="$c" lib_resolve)
  refout=$(CS_ROOT_OVERRIDE="$r" CS_HOME="$h" CS_DATA_OVERRIDE="$d" CS_STATE_OVERRIDE="$s" CS_CONFIG_OVERRIDE="$c" ref_resolve)
  if [ "$libout" != "$refout" ]; then
    printf 'mask=%s\n--- lib ---\n%s\n--- ref ---\n%s\n' "$mask" "$libout" "$refout" >&2
    mismatch=1
  fi
done
[ "$mismatch" -eq 0 ] || fail "cs_resolve_root diverged from the inline reference for some override combination"
pass "all 32 override combinations resolve byte-identically to the inline reference"

# --- relative inputs are anchored, never handed on relative -------------------
#
# These values do not stay inside one process: they are baked into durable
# soldier briefs and capo charters and restated on launch lines and daemon
# handoffs that other processes run from a different working directory. A
# relative value would silently name a different directory in each of them.

TMP=$(cs_test_tmproot cs-root-lib)
mkdir -p "$TMP"
# TMPDIR can carry a trailing slash, which $PWD normalizes away; compare against
# the same normalized form the resolver will produce.
TMP=$(cd "$TMP" && pwd)
mkdir -p "$TMP/homes/alpha" "$TMP/elsewhere"

# A relative CS_HOME resolves against the resolving process's cwd, and every
# derived path inherits that anchor.
out=$(cd "$TMP/homes" && CS_ROOT_OVERRIDE='' CS_HOME='alpha' \
  CS_DATA_OVERRIDE='' CS_STATE_OVERRIDE='' CS_CONFIG_OVERRIDE='' lib_resolve)
read_resolved "$out"
case "$g_home" in
  /*) ;;
  *) fail "a relative CS_HOME must resolve absolute, got '$g_home'" ;;
esac
[ "$g_home" = "$TMP/homes/alpha" ] || fail "relative CS_HOME anchored to '$g_home', expected $TMP/homes/alpha"
[ "$g_data" = "$TMP/homes/alpha/data" ] || fail "DATA did not follow the anchored home: $g_data"
[ "$g_state" = "$TMP/homes/alpha/state" ] || fail "STATE did not follow the anchored home: $g_state"
[ "$g_config" = "$TMP/homes/alpha/config" ] || fail "CONFIG did not follow the anchored home: $g_config"
pass "a relative CS_HOME is anchored, and data/state/config follow it"

# The anchored value is what a later process at a DIFFERENT cwd would receive.
# Re-resolving that absolute value from elsewhere must land in the same place -
# which is exactly what a bare relative value would have failed to do.
out=$(cd "$TMP/elsewhere" && CS_ROOT_OVERRIDE='' CS_HOME="$g_home" \
  CS_DATA_OVERRIDE='' CS_STATE_OVERRIDE='' CS_CONFIG_OVERRIDE='' lib_resolve)
read_resolved "$out"
[ "$g_home" = "$TMP/homes/alpha" ] || fail "the anchored home moved when re-resolved from another cwd: $g_home"
# Counterproof: the raw relative value really would have moved.
out=$(cd "$TMP/elsewhere" && CS_ROOT_OVERRIDE='' CS_HOME='alpha' \
  CS_DATA_OVERRIDE='' CS_STATE_OVERRIDE='' CS_CONFIG_OVERRIDE='' lib_resolve)
read_resolved "$out"
[ "$g_home" = "$TMP/elsewhere/alpha" ] ||
  fail "expected the relative value to anchor to the second cwd, got '$g_home'"
pass "an anchored home survives a handoff to a process with a different cwd"

# A relative state/data override is anchored on its own, not only via CS_HOME.
out=$(cd "$TMP/elsewhere" && CS_ROOT_OVERRIDE='' CS_HOME="$TMP/homes/alpha" \
  CS_DATA_OVERRIDE='rel-data' CS_STATE_OVERRIDE='rel-state' CS_CONFIG_OVERRIDE='' lib_resolve)
read_resolved "$out"
[ "$g_data" = "$TMP/elsewhere/rel-data" ] || fail "relative CS_DATA_OVERRIDE not anchored: $g_data"
[ "$g_state" = "$TMP/elsewhere/rel-state" ] || fail "relative CS_STATE_OVERRIDE not anchored: $g_state"
pass "relative data and state overrides are anchored independently of CS_HOME"

# Anchoring must not require the directory to exist: DATA/STATE/CONFIG are
# routinely resolved before anything has created them.
out=$(cd "$TMP/elsewhere" && CS_ROOT_OVERRIDE='' CS_HOME='not-created-yet' \
  CS_DATA_OVERRIDE='' CS_STATE_OVERRIDE='' CS_CONFIG_OVERRIDE='' lib_resolve) ||
  fail "resolution must not require the home to exist yet"
read_resolved "$out"
[ "$g_home" = "$TMP/elsewhere/not-created-yet" ] || fail "absent home not anchored: $g_home"
pass "anchoring does not require the directory to exist"

# cs_abs_path itself: absolute passes through byte-identical, empty refuses.
[ "$(cs_abs_path /a/b)" = "/a/b" ] || fail "an absolute path must pass through unchanged"
if cs_abs_path '' 2>/dev/null; then fail "cs_abs_path must refuse an empty path"; fi
pass "cs_abs_path passes absolute paths through and refuses an empty one"

# --- idempotent double-source -----------------------------------------------
# Sourcing again must not error or clobber the function (guard returns early).
. "$ROOT/bin/cs-root-lib.sh"
out=$(CS_ROOT_OVERRIDE='' CS_HOME='' CS_DATA_OVERRIDE='' CS_STATE_OVERRIDE='' CS_CONFIG_OVERRIDE='' lib_resolve)
read_resolved "$out"
[ "$g_root" = "$REPO_ROOT" ] || fail "re-sourced cs_resolve_root still resolves (got $g_root)"
pass "library is idempotent under double-source"
