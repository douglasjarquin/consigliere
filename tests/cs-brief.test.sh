#!/usr/bin/env bash
# Behavior: cs-brief.sh scaffolds ship/scout/capo briefs shaped by delivery
# mode, refuses overwrite, gates --herdr-lab flags, and embeds the safety
# contracts (isolation assertion, status protocol, marker contract).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(cs_test_tmproot cs-brief)
export CS_DATA_OVERRIDE="$TMP/data"
export CS_STATE_OVERRIDE="$TMP/state"
mkdir -p "$TMP/data" "$TMP/state"

BIN="$ROOT/bin/cs-brief.sh"

cat > "$TMP/data/projects.md" <<'EOF'
- alpha - default mode (added 2026-07-01)
- beta [direct-PR] - direct (added 2026-07-01)
- gamma [local-only] - local (added 2026-07-01)
EOF

# ship, no-mistakes default
out=$("$BIN" t1 alpha)
assert_contains "$out" "mode=no-mistakes" "ship scaffold reports mode"
B="$TMP/data/t1/brief.md"
assert_present "$B" "ship brief written"
assert_grep 'Verify isolation before anything else' "$B" "isolation assertion present"
assert_grep 'cs/t1' "$B" "task branch named"
assert_grep 'blocked: launched outside the isolated task worktree' "$B" "isolation stop instruction"
assert_grep 'no-mistakes doctor' "$B" "no-mistakes setup step present"
assert_grep 'Herdr lifecycle declaration - NOT ENABLED' "$B" "unguarded herdr declaration present"
assert_grep 'checks green' "$B" "no-mistakes definition of done"
# The implementation commit is reported as needs-review, never done: a keyed
# open state keeps an unreviewed commit visible, where done: read as finished.
assert_grep 'needs-review: {summary of what you built}' "$B" "no-mistakes commit reports needs-review"
assert_grep 'this mode adds that one state to the list in rule 4' "$B" "no-mistakes brief forbids done: at the commit"
assert_no_grep 'done: {summary}' "$B" "the ambiguous commit-time done: is gone"
pass "ship brief (no-mistakes) scaffold"

# refuse overwrite
if "$BIN" t1 alpha >/dev/null 2>&1; then
  fail "second scaffold for t1 must refuse"
fi
pass "existing brief refuses overwrite"

# direct-PR shaping
"$BIN" t2 beta >/dev/null
B="$TMP/data/t2/brief.md"
assert_grep 'direct-PR' "$B" "direct-PR named"
assert_grep 'done: PR {url}' "$B" "direct-PR done signal"
assert_no_grep 'no-mistakes doctor' "$B" "no pipeline setup in direct-PR"
pass "ship brief (direct-PR) scaffold"

# local-only shaping
"$BIN" t3 gamma >/dev/null
B="$TMP/data/t3/brief.md"
assert_grep 'ready in branch cs/t3' "$B" "local-only done signal"
assert_grep 'Never push to any remote' "$B" "local-only forbids push"
pass "ship brief (local-only) scaffold"

# needs-review is mode-specific: direct-PR and local-only have no pre-validation
# review step, so their briefs must not mention it.
for t in t2 t3; do
  assert_no_grep 'needs-review' "$TMP/data/$t/brief.md" "no needs-review outside no-mistakes ($t)"
done
pass "needs-review appears only in no-mistakes briefs"

# scout
"$BIN" t4 alpha --scout >/dev/null
B="$TMP/data/t4/brief.md"
assert_grep 'SCOUT task' "$B" "scout contract named"
assert_grep 'report.md' "$B" "report deliverable named"
assert_grep 'Never push to any remote and never open a PR' "$B" "scout forbids push"
pass "scout brief scaffold"

# Unmarked-message rule: an ordinary soldier must recognize the boss typing into
# its pane AND still close the decision key, because the keyed status fold keeps
# a needs-decision open in every home above until a matching resolved line lands.
for t in t1 t2 t3 t4; do
  B="$TMP/data/$t/brief.md"
  assert_grep 'A message WITHOUT that marker is the boss typing directly into your pane' \
    "$B" "$t brief names unmarked boss intervention"
  assert_grep 'stays open above you until you close it' \
    "$B" "$t brief still requires the resolved line after a direct boss answer"
done
pass "ship and scout briefs carry the unmarked-boss-message rule"

# herdr-lab section
"$BIN" t5 alpha --herdr-lab >/dev/null
B="$TMP/data/t5/brief.md"
assert_grep 'HARD SAFETY CONTRACT' "$B" "herdr-lab contract present"
assert_grep 'cs-herdr-lab.sh' "$B" "lab helper referenced"
pass "herdr-lab guarded brief"

# --issue linkage: PR-mode brief carries the hard Closes contract
"$BIN" t7 alpha --issue 42 >/dev/null
B="$TMP/data/t7/brief.md"
assert_grep 'Board issue #42' "$B" "issue section present"
assert_grep 'Closes #42' "$B" "PR must close the issue"
assert_grep 'Do NOT edit the project board yourself' "$B" "no self board edits"
pass "ship brief --issue bakes in the Closes contract"

# --issue on local-only: no PR, consigliere closes after local merge
"$BIN" t8 gamma --issue 43 >/dev/null
B="$TMP/data/t8/brief.md"
assert_grep 'consigliere closes issue #43 after' "$B" "local-only issue closed by consigliere"
assert_no_grep 'Closes #43' "$B" "no PR keyword on local-only"
pass "ship brief --issue local-only variant"

# --issue rejected on scout and non-numeric
if "$BIN" t9 alpha --scout --issue 5 >/dev/null 2>&1; then fail "--issue on scout must refuse"; fi
if "$BIN" t10 alpha --issue abc >/dev/null 2>&1; then fail "non-numeric --issue must refuse"; fi
pass "--issue misuse refusals"

# capo charter
CS_CAPO_CHARTER='Own the data-platform domain.' "$BIN" c1 --capo alpha beta >/dev/null
B="$TMP/data/c1/brief.md"
assert_grep 'persistent capo' "$B" "capo identity"
assert_grep '[cs-from-consigliere]' "$B" "marker contract in charter"
assert_grep 'corr=<id>' "$B" "correlation token contract"
assert_grep 'Own the data-platform domain.' "$B" "charter text filled"
assert_grep '- alpha' "$B" "project list rendered"
pass "capo charter scaffold"

# capo requires projects or --no-projects
if "$BIN" c2 --capo >/dev/null 2>&1; then
  fail "capo scaffold without projects must refuse"
fi
"$BIN" c3 --capo --no-projects >/dev/null
assert_grep 'project-less domain' "$TMP/data/c3/brief.md" "no-projects charter"
pass "capo project-list gating"

# flag misuse
if "$BIN" c4 --capo alpha --herdr-lab >/dev/null 2>&1; then
  fail "--herdr-lab on capo must refuse"
fi
if "$BIN" t6 alpha --no-projects >/dev/null 2>&1; then
  fail "--no-projects on ship must refuse"
fi
pass "flag misuse refusals"

pass "cs-brief behaviors"
