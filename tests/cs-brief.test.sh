#!/usr/bin/env bash
# Behavior: cs-brief.sh scaffolds ship/scout/capo briefs shaped by the explicit
# --mode, refuses overwrite, gates --herdr-lab flags, and embeds the safety
# contracts (isolation assertion, status protocol, marker contract).
# The delivery contract itself - required/refused --mode, the no-yolo rule, and
# the machine-readable contract line - is owned by tests/cs-task-delivery.test.sh.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(cs_test_tmproot cs-brief)
export CS_DATA_OVERRIDE="$TMP/data"
export CS_STATE_OVERRIDE="$TMP/state"
mkdir -p "$TMP/data" "$TMP/state"

BIN="$ROOT/bin/cs-brief.sh"

# No projects.md fixture: cs-brief.sh does not read the registry at all. The
# delivery mode arrives as an explicit --mode, and every repo/project name below
# is just a string the scaffold echoes back. A registry entry here would only
# suggest the scaffold still consults one.

# ship, --mode no-mistakes
out=$("$BIN" t1 alpha --mode no-mistakes)
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
# The pipeline reviews against --intent, so a soldier that passes a diff summary
# instead of the accepted contract gets reviewed against less than it agreed to.
# shellcheck disable=SC2016  # literal grep patterns; backticks are brief markup, not expansion
assert_grep 'make `--intent` preserve all relevant content' "$B" \
  "no-mistakes brief requires --intent to carry the accepted task contract"
assert_grep "carrying only each requirement's current accepted form" "$B" \
  "no-mistakes brief requires superseded requirements to carry their current form"
assert_grep 'retain the direct requirements instead of substituting a summary of your diff' "$B" \
  "no-mistakes brief forbids a diff summary in place of the requirements"
assert_grep 'leave out generic operational, status, delivery, and other scaffold boilerplate' "$B" \
  "no-mistakes brief excludes scaffold boilerplate from --intent"
pass "ship brief (no-mistakes) scaffold"

# refuse overwrite
if "$BIN" t1 alpha --mode no-mistakes >/dev/null 2>&1; then
  fail "second scaffold for t1 must refuse"
fi
pass "existing brief refuses overwrite"

# direct-PR shaping
"$BIN" t2 beta --mode direct-PR >/dev/null
B="$TMP/data/t2/brief.md"
assert_grep 'direct-PR' "$B" "direct-PR named"
assert_grep 'done: PR {url}' "$B" "direct-PR done signal"
assert_no_grep 'no-mistakes doctor' "$B" "no pipeline setup in direct-PR"
pass "ship brief (direct-PR) scaffold"

# local-only shaping
"$BIN" t3 gamma --mode local-only >/dev/null
B="$TMP/data/t3/brief.md"
assert_grep 'ready in branch cs/t3' "$B" "local-only done signal"
assert_grep 'Never push to any remote' "$B" "local-only forbids push"
pass "ship brief (local-only) scaffold"

# needs-review is mode-specific: direct-PR and local-only have no pre-validation
# review step, so their briefs must not mention it.
for t in t2 t3; do
  assert_no_grep 'needs-review' "$TMP/data/$t/brief.md" "no needs-review outside no-mistakes ($t)"
  # shellcheck disable=SC2016  # literal grep pattern; backticks are brief markup, not expansion
  assert_no_grep 'make `--intent` preserve all relevant content' "$TMP/data/$t/brief.md" \
    "no --intent contract outside no-mistakes ($t)"
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
"$BIN" t5 alpha --mode no-mistakes --herdr-lab >/dev/null
B="$TMP/data/t5/brief.md"
assert_grep 'HARD SAFETY CONTRACT' "$B" "herdr-lab contract present"
assert_grep 'cs-herdr-lab.sh' "$B" "lab helper referenced"
pass "herdr-lab guarded brief"

# --issue linkage: PR-mode brief carries the hard Closes contract
"$BIN" t7 alpha --mode no-mistakes --issue 42 >/dev/null
B="$TMP/data/t7/brief.md"
assert_grep 'Board issue #42' "$B" "issue section present"
assert_grep 'Closes #42' "$B" "PR must close the issue"
assert_grep 'Do NOT edit the project board yourself' "$B" "no self board edits"
pass "ship brief --issue bakes in the Closes contract"

# --issue on local-only: no PR, consigliere closes after local merge
"$BIN" t8 gamma --mode local-only --issue 43 >/dev/null
B="$TMP/data/t8/brief.md"
assert_grep 'consigliere closes issue #43 after' "$B" "local-only issue closed by consigliere"
assert_no_grep 'Closes #43' "$B" "no PR keyword on local-only"
pass "ship brief --issue local-only variant"

# --issue rejected on scout and non-numeric
if "$BIN" t9 alpha --scout --issue 5 >/dev/null 2>&1; then fail "--issue on scout must refuse"; fi
if "$BIN" t10 alpha --mode no-mistakes --issue abc >/dev/null 2>&1; then fail "non-numeric --issue must refuse"; fi
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
if "$BIN" t6 alpha --mode no-mistakes --no-projects >/dev/null 2>&1; then
  fail "--no-projects on ship must refuse"
fi
pass "flag misuse refusals"

# --exec-mode fixture: a fake omo plugin cache for both harnesses, isolated
# from the developer's own real ~/.codex and ~/.claude installs, so every
# assertion below is deterministic regardless of what is actually installed
# on the machine running this suite.
export CODEX_HOME="$TMP/fake-codex-home"
export CLAUDE_CONFIG_DIR="$TMP/fake-claude-home"
mkdir -p "$CODEX_HOME/plugins/cache/sisyphuslabs/omo" "$CLAUDE_CONFIG_DIR/plugins/cache/sisyphuslabs/omo"

# --exec-mode: default is ultrawork (codex, the ambient CS_HARNESS_OVERRIDE
# from lib.sh), embedding the literal self-activating word and nothing plan-related.
"$BIN" e1 alpha --mode local-only >/dev/null
B="$TMP/data/e1/brief.md"
assert_grep '# Execution mode' "$B" "default exec-mode section present"
assert_grep 'Use ultrawork for this task' "$B" "default exec-mode names ultrawork"
assert_no_grep 'plan first' "$B" "default exec-mode carries no plan-first wording"
out=$("$BIN" e1b alpha --mode local-only)
assert_contains "$out" "exec-mode=ultrawork" "default exec-mode echoed"
pass "ship brief defaults --exec-mode to ultrawork"

# --exec-mode plan-first on codex: the harness-correct plan/start-work skill
# strings, the needs-decision checkpoint, the forbidden-flags clause, and the
# .gitignore/.omo reminder.
"$BIN" e2 alpha --mode local-only --exec-mode plan-first >/dev/null
B="$TMP/data/e2/brief.md"
assert_grep '# Execution mode - plan first' "$B" "plan-first section present"
# shellcheck disable=SC2016  # literal grep patterns; backticks are brief markup, not expansion
assert_grep 'Invoke `ulw-plan`' "$B" "codex plan-first names ulw-plan"
# shellcheck disable=SC2016  # literal grep patterns; backticks are brief markup, not expansion
assert_grep 'invoke `start-work`' "$B" "codex plan-first names start-work"
assert_grep 'needs-decision: plan ready for review' "$B" "plan-first stops at needs-decision"
assert_grep 'Do NOT pass any ship/PR/merge flag' "$B" "plan-first forbids start-work ship flags"
assert_grep '.gitignore' "$B" "plan-first reminds about .omo/ in .gitignore"
pass "ship brief --exec-mode plan-first on codex names ulw-plan/start-work"

# --exec-mode plan-first on claude: same checkpoint, claude's own skill strings.
CS_HARNESS_OVERRIDE=claude "$BIN" e3 alpha --mode local-only --exec-mode plan-first >/dev/null
B="$TMP/data/e3/brief.md"
# shellcheck disable=SC2016  # literal grep patterns; backticks are brief markup, not expansion
assert_grep 'Invoke `omo:planing-prometheustic`' "$B" "claude plan-first names omo:planing-prometheustic"
# shellcheck disable=SC2016  # literal grep patterns; backticks are brief markup, not expansion
assert_grep 'invoke `omo:start-work`' "$B" "claude plan-first names omo:start-work"
pass "ship brief --exec-mode plan-first on claude names omo:planing-prometheustic/omo:start-work"

# misuse: an out-of-set value refuses; exec-mode is ship-only.
if "$BIN" e4 alpha --mode local-only --exec-mode bogus >/dev/null 2>&1; then
  fail "--exec-mode bogus must refuse"
fi
if "$BIN" e5 alpha --scout --exec-mode ultrawork >/dev/null 2>&1; then
  fail "--exec-mode on a scout must refuse"
fi
# Regression guard for the Momus-caught ordering bug: an ordinary scout with NO
# --exec-mode flag at all must never reach the ship-only default-resolution
# code path, so it scaffolds exactly as it did before this flag existed.
"$BIN" e6 alpha --scout >/dev/null || fail "a scout with no --exec-mode must still scaffold"
assert_no_grep 'Execution mode' "$TMP/data/e6/brief.md" "a scout brief carries no execution-mode section at all"
pass "--exec-mode misuse refusals and the scout regression guard"

# omo guard: plan-first refuses loudly when the omo plugin is absent for the
# resolved harness; ultrawork only warns, since it degrades to plain text
# rather than a dead skill invocation.
NO_OMO_CODEX="$TMP/no-omo-codex-home"
NO_OMO_CLAUDE="$TMP/no-omo-claude-home"

err=$(CODEX_HOME="$NO_OMO_CODEX" "$BIN" e7 alpha --mode local-only --exec-mode plan-first 2>&1)
rc=$?
[ "$rc" -ne 0 ] || fail "plan-first with no omo installed must refuse"
assert_contains "$err" "omo plugin is not installed" "the plan-first-no-omo refusal names the missing plugin"
assert_absent "$TMP/data/e7" "a refused plan-first-no-omo scaffold leaves no task directory behind"

out=$(CODEX_HOME="$NO_OMO_CODEX" "$BIN" e8 alpha --mode local-only 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "ultrawork default with no omo installed must still scaffold: $out"
assert_contains "$out" "warning: omo plugin not installed" "ultrawork-no-omo warns rather than refuses"
assert_present "$TMP/data/e8/brief.md" "ultrawork-no-omo still scaffolds a brief"
assert_grep 'Use ultrawork for this task' "$TMP/data/e8/brief.md" "ultrawork-no-omo brief still names ultrawork"

CLAUDE_CONFIG_DIR="$NO_OMO_CLAUDE" CS_HARNESS_OVERRIDE=claude "$BIN" e9 alpha --mode local-only --exec-mode plan-first >/dev/null 2>&1 \
  && fail "claude plan-first with no omo installed must refuse"
assert_absent "$TMP/data/e9" "a refused claude plan-first-no-omo scaffold leaves no task directory behind"
pass "the omo guard refuses plan-first and warns-but-proceeds on ultrawork when the plugin is absent"

pass "cs-brief behaviors"
