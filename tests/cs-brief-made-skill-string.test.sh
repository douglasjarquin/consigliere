#!/usr/bin/env bash
# Behavior: cs-brief.sh's no-mistakes-mode Definition-of-done section drives a
# soldier directly - it names the skill-invocation string (`$no-mistakes`) and
# the operational prose around it (doctor/init setup, "owns the PR object",
# "You drive no-mistakes by responding to its gates", the `axi run --help`/
# `axi respond` mechanics references, and the CI-green completion line). Task
# 23 shipped made (skills/made/SKILL.md) as the replacement skill, so this
# suite pins those exact seven sites to `made`/`$made` and made's own real CLI
# surface (`made doctor`, `made gate init`, `made status --json`, `made
# review`) instead of no-mistakes' `axi` namespace, which made does not have.
#
# Scope note: this suite intentionally does NOT assert on the file's
# mode-semantics/dispatch sites (the `--mode made` value itself, the
# shared-daemon restart rule, the `elif [ "$MODE" = made ]` dispatch, etc.) -
# those belong to a separate migration task (mode-semantics migration). The
# `--mode made` invocations below exist only to reach the ship-mode DoD
# section; every assertion greps for a phrase that is unique to the seven
# skill-invocation/prose sites, verified by hand against a fresh grep of the
# whole file, so this suite cannot pass or fail on the other task's territory.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(cs_test_tmproot cs-brief-made-skill-string)
export CS_DATA_OVERRIDE="$TMP/data"
export CS_STATE_OVERRIDE="$TMP/state"
mkdir -p "$TMP/data" "$TMP/state"

BIN="$ROOT/bin/cs-brief.sh"

check_brief_skill_sites() {
  local B=$1 label=$2

  # Positive: the skill-invocation string and its surrounding prose all name
  # made and made's own real CLI surface.
  assert_grep 'made doctor' "$B" "$label: setup step runs made doctor"
  assert_grep 'made gate init' "$B" "$label: setup step's init fallback runs made gate init"
  # shellcheck disable=SC2016  # literal fixed-string pattern, not a shell expansion
  assert_grep '$made' "$B" "$label: the skill-invocation string is \$made"
  assert_grep 'made owns the PR object end to end' "$B" "$label: PR-ownership prose names made"
  assert_grep 'You drive made by responding to its gates' "$B" "$label: gate-driving prose names made"
  assert_grep 'made status --json' "$B" "$label: mechanics reference points at made status --json"
  assert_grep 'made review' "$B" "$label: ask-user-decision feedback goes through made review"
  # shellcheck disable=SC2016  # literal fixed-string pattern, not a shell expansion
  assert_grep '$made reports CI green' "$B" "$label: CI-green completion line invokes \$made"

  # Negative: none of the seven sites' original no-mistakes phrasing survives.
  # Each phrase below is unique to one of the seven sites (hand-verified
  # against a full-file grep), so these cannot false-fail against the
  # separate mode-semantics migration's own still-"no-mistakes" territory
  # (e.g. the shared-daemon rule, or "no-mistakes axi run" without --help in
  # the --issue section).
  assert_no_grep 'no-mistakes doctor' "$B" "$label: no stale no-mistakes doctor instruction"
  assert_no_grep 'no-mistakes init' "$B" "$label: no stale no-mistakes init instruction"
  assert_no_grep 'no-mistakes owns the PR object' "$B" "$label: no stale no-mistakes PR-ownership prose"
  assert_no_grep 'You drive no-mistakes' "$B" "$label: no stale no-mistakes gate-driving prose"
  assert_no_grep 'no-mistakes axi run --help' "$B" "$label: no stale no-mistakes axi run --help reference"
  assert_no_grep 'no-mistakes axi respond' "$B" "$label: no stale no-mistakes axi respond instruction"
  # shellcheck disable=SC2016  # literal fixed-string pattern, not a shell expansion
  assert_no_grep '$no-mistakes' "$B" "$label: no stale \$no-mistakes invocation string"
}

# codex harness (ambient default from lib.sh / CS_HARNESS_OVERRIDE=codex).
"$BIN" sk1 alpha --mode made >/dev/null
check_brief_skill_sites "$TMP/data/sk1/brief.md" "codex"
pass "codex made-mode brief names made at every skill-invocation site"

# claude harness: same seven sites, since they sit in the mode-shaped
# Definition-of-done block, which does not branch on harness.
CS_HARNESS_OVERRIDE=claude "$BIN" sk2 alpha --mode made >/dev/null
check_brief_skill_sites "$TMP/data/sk2/brief.md" "claude"
pass "claude made-mode brief names made at every skill-invocation site"

pass "cs-brief made skill-string migration"
