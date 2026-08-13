#!/usr/bin/env bash
# tests/skill-inventory.test.sh - the skill surface stays internally consistent.
#
# Why this exists: a skill is loaded by NAME from a trigger written in AGENTS.md.
# Rename a skill and miss one of those triggers, and the result is silent - the
# playbook simply never loads again, with no error anywhere. Nothing caught that
# before this test, which is exactly the risk a rename runs.
#
# Three invariants:
#   1. Every skills/<dir>/SKILL.md declares `name: <dir>` - the loader resolves
#      by directory, so a mismatched name field is a latent trap.
#   2. Every skill AGENTS.md tells an agent to load exists on disk.
#   3. Every `/slash` invocation AGENTS.md promises the boss resolves to a skill.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILLS="$ROOT/skills"
AGENTS="$ROOT/AGENTS.md"

[ -d "$SKILLS" ] || fail "no skills directory at $SKILLS"
[ -f "$AGENTS" ] || fail "no AGENTS.md at $AGENTS"

# 1. name field matches the directory the loader resolves by.
count=0
for dir in "$SKILLS"/*/; do
  [ -d "$dir" ] || continue
  name=$(basename "$dir")
  skill="$dir/SKILL.md"
  [ -f "$skill" ] || fail "skills/$name has no SKILL.md"
  declared=$(sed -n 's/^name: *//p' "$skill" | head -1)
  [ -n "$declared" ] || fail "skills/$name/SKILL.md declares no name field"
  [ "$declared" = "$name" ] \
    || fail "skills/$name/SKILL.md declares name '$declared'; the loader resolves by directory, so it must be '$name'"
  count=$((count + 1))
done
[ "$count" -gt 0 ] || fail "no skills found to check"
pass "every skill's name field matches its directory ($count skills)"

# 2. every skill AGENTS.md tells an agent to load exists.
# Matches the two shapes the contract uses: "load `x`" and "load the `x` skill".
missing=""
# shellcheck disable=SC2016  # the backticks are literal AGENTS.md markup to match, not command substitution.
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  [ -d "$SKILLS/$ref" ] && continue
  case " $missing " in *" $ref "*) ;; *) missing="$missing $ref" ;; esac
done <<EOF
$(grep -oE 'load (the )?`[a-z0-9-]+`' "$AGENTS" | grep -oE '`[a-z0-9-]+`' | tr -d '`' | sort -u)
EOF
[ -z "$missing" ] || fail "AGENTS.md tells agents to load skills that do not exist:$missing"
pass "every skill AGENTS.md instructs an agent to load exists on disk"

# 3. every slash command AGENTS.md promises the boss resolves to a skill.
# Skipped names are harness built-ins or external tools, not consigliere skills.
missing=""
# shellcheck disable=SC2016  # the backticks are literal AGENTS.md markup to match, not command substitution.
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  case "$cmd" in no-mistakes|help|clear) continue ;; esac
  [ -d "$SKILLS/$cmd" ] && continue
  case " $missing " in *" $cmd "*) ;; *) missing="$missing $cmd" ;; esac
done <<EOF
$(grep -oE '`/[a-z0-9-]+`' "$AGENTS" | tr -d '`/' | sort -u)
EOF
[ -z "$missing" ] || fail "AGENTS.md promises slash commands with no matching skill:$missing"
pass "every slash command AGENTS.md promises the boss resolves to a skill"

# 4. /afk is the one canonical owner of bossless mode: the old orthogonality
#    claim decisions 1+2 invert must be gone (a specific known-wrong claim this
#    guards against reintroducing), and a Bossless mode section must exist to
#    own it. The load-bearing claims' actual substance is a one-time Plan
#    Compliance Audit concern, not a standing prose-matching regression test:
#    a meaning-preserving rewrite of that section must not fail this suite.
AFK_SKILL="$SKILLS/afk/SKILL.md"
grep -q "still waits for the boss's explicit word" "$AFK_SKILL" \
  && fail "skills/afk/SKILL.md still carries the old orthogonality claim decisions 1+2 invert"
grep -q "^## Bossless mode" "$AFK_SKILL" || fail "skills/afk/SKILL.md is missing its Bossless mode section"
pass "skills/afk/SKILL.md is the one canonical owner of bossless mode's scope and boundaries"

pass "skill inventory is internally consistent"
