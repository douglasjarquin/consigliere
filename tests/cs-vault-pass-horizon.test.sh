#!/usr/bin/env bash
# Contract: skills/vault pass-horizon decay and config/vault-pass-horizon.conf
# stay documented in the skill and docs/configuration.md.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SKILL="$ROOT/skills/vault/SKILL.md"
CONFIG="$ROOT/docs/configuration.md"

assert_grep 'vault-pass-horizon.conf' "$CONFIG" \
  "configuration.md documents the opt-in pass-horizon flag"
assert_grep 'whichever horizon hits first' "$CONFIG" \
  "configuration.md names the first-hit rule"
assert_grep 'vault-pass-horizon.conf' "$SKILL" \
  "vault skill documents the opt-in flag"
assert_grep 'reinforced 2026-08-11/3' "$SKILL" \
  "vault skill documents the /N marker suffix"
assert_grep 'unreinforced <N>p' "$SKILL" \
  "vault skill documents the pass-only archive reason"
assert_grep '10 passes' "$SKILL" \
  "vault skill documents the aging pass threshold"
assert_grep '3 unreinforced passes' "$SKILL" \
  "vault skill documents the perishable pass threshold"

printf 'all cs-vault-pass-horizon tests passed\n'
