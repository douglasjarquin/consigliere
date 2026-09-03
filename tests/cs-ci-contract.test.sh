#!/usr/bin/env bash
# Behavior (portable): the CI contract. Protects the guarantees that let hosted
# CI, local runs, and the coverage guard stay in lockstep, so a change that would
# silently weaken CI fails this hermetic test first.
#
# Covers: the lane partition and coverage guard; single-owner pins (ShellCheck
# version, Herdr version + protocol floor); and the workflow calling only the
# repository-owned entrypoints (no re-spelled commands, live-codex never run in
# hosted CI).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WF="$ROOT/.github/workflows/ci.yml"
RUN="$ROOT/bin/cs-test-run.sh"
LINT="$ROOT/bin/cs-lint.sh"

TMP=$(cs_test_tmproot cs-ci-python)
PY39BIN="$TMP/python39-bin"
mkdir -p "$PY39BIN"
cat > "$PY39BIN/python3" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'Python 3.9.6\n'
  exit 0
fi
printf 'ModuleNotFoundError: No module named tomllib\n' >&2
exit 1
SH
chmod +x "$PY39BIN/python3"
runner_out=$(PATH="$PY39BIN:$PATH" "$RUN" tests/cs-harness-lib.test.sh 2>&1) &&
  fail 'test runner must reject Python 3.9'
assert_contains "$runner_out" 'Python 3.11+' 'runner preflight states the supported Python floor'
assert_contains "$runner_out" tomllib 'runner preflight names the stdlib capability'
assert_not_contains "$runner_out" 'cs-test-run: running tests/cs-harness-lib.test.sh' \
  'runner preflight must run before invoking tests'
pass 'test runner fails closed before a late tomllib import'

# --- lane partition + coverage guard ---------------------------------------

# The ok summary goes to stdout; the "excluded" report goes to stderr, so
# capture both.
out=$("$RUN" --check-coverage 2>&1) || fail "coverage guard must exit 0 on a healthy tree"
assert_contains "$out" "CS_TEST_COVERAGE ok" "coverage guard prints its ok summary"
pass "coverage guard passes"

inventory=( "$ROOT"/tests/*.test.sh )
all_count=${#inventory[@]}
p=$("$RUN" --list --portable | grep -c .)
h=$("$RUN" --list --herdr | grep -c .)
d=$("$RUN" --list --docker | grep -c .)
c=$("$RUN" --list --lane live-codex | grep -c .)
cl=$("$RUN" --list --lane live-claude | grep -c .)
[ "$((p + h + d + c + cl))" -eq "$all_count" ] \
  || fail "lanes ($p+$h+$d+$c+$cl) must sum to the inventory ($all_count)"
pass "portable + real-herdr + real-docker + live-codex + live-claude partition the whole inventory"

# No script may appear in two lanes.
dups=$({ "$RUN" --list --portable; "$RUN" --list --herdr; "$RUN" --list --docker; "$RUN" --list --lane live-codex; "$RUN" --list --lane live-claude; } \
  | LC_ALL=C sort | uniq -d)
[ -z "$dups" ] || fail "a test is categorized into more than one lane: $dups"
pass "no test appears in two lanes"

# The live-only families keep their exact, self-gating lane.
[ "$("$RUN" --lane-of cs-herdr-lib-live.test.sh)" = "real-herdr" ] \
  || fail "cs-herdr-lib-live must be the real-herdr lane"
[ "$("$RUN" --lane-of cs-lifecycle-live.test.sh)" = "live-codex" ] \
  || fail "cs-lifecycle-live must be the live-codex lane"
[ "$("$RUN" --lane-of cs-lifecycle-claude-live.test.sh)" = "live-claude" ] \
  || fail "cs-lifecycle-claude-live must be the live-claude lane"
assert_contains "$out" "excluded (CS_TEST_CODEX_LIVE)" \
  "coverage guard reports live-codex as visibly excluded, not silently dropped"
assert_contains "$out" "excluded (CS_TEST_CLAUDE_LIVE)" \
  "coverage guard reports live-claude as visibly excluded, not silently dropped"
pass "live-only lanes are pinned and live-codex is visibly excluded"

[ "$("$RUN" --lane-of cs-dev-tools.test.sh)" = "real-docker" ] \
  || fail "cs-dev-tools must be the real-docker lane"
pass "the real-docker lane is pinned to cs-dev-tools.test.sh"

# --- single-owner pins ------------------------------------------------------

# ShellCheck version: cs-lint.sh owns it; the installer reads it, never re-pins.
sc_version=$("$LINT" --required-version)
[ -n "$sc_version" ] || fail "cs-lint.sh --required-version must print a version"
# shellcheck disable=SC2016  # literal grep pattern; no expansion wanted
assert_grep '"$ROOT/bin/cs-lint.sh" --required-version' "$ROOT/bin/cs-install-shellcheck.sh" \
  "cs-install-shellcheck.sh must read the version from cs-lint.sh"
assert_no_grep 'REQUIRED_SHELLCHECK=' "$ROOT/bin/cs-install-shellcheck.sh" \
  "cs-install-shellcheck.sh must not re-declare the ShellCheck version"
pass "ShellCheck version has one owner (cs-lint.sh)"

# actionlint version: cs-lint-workflows.sh owns it; the installer reads it.
al_version=$("$ROOT/bin/cs-lint-workflows.sh" --required-version)
[ -n "$al_version" ] || fail "cs-lint-workflows.sh --required-version must print a version"
# shellcheck disable=SC2016
assert_grep '"$ROOT/bin/cs-lint-workflows.sh" --required-version' "$ROOT/bin/cs-install-actionlint.sh" \
  "cs-install-actionlint.sh must read the version from cs-lint-workflows.sh"
assert_no_grep 'REQUIRED_ACTIONLINT=' "$ROOT/bin/cs-install-actionlint.sh" \
  "cs-install-actionlint.sh must not re-declare the actionlint version"
pass "actionlint version has one owner (cs-lint-workflows.sh)"

# Herdr protocol floor: cs-herdr-lib.sh owns it; the installer reads it.
floor=$(awk -F= '/^CS_HERDR_MIN_PROTOCOL=/ { gsub(/[^0-9]/, "", $2); print $2; exit }' \
  "$ROOT/bin/cs-herdr-lib.sh")
[ -n "$floor" ] || fail "cs-herdr-lib.sh must define CS_HERDR_MIN_PROTOCOL"
assert_grep 'CS_HERDR_MIN_PROTOCOL=' "$ROOT/bin/cs-install-herdr.sh" \
  "cs-install-herdr.sh must read the protocol floor from cs-herdr-lib.sh"
# Derive the pin instead of restating it. cs-install-herdr.sh's header calls
# itself "the single owner of the exact Herdr version"; a hard-coded copy here
# is a second owner that has to be remembered on every bump, and this assertion
# previously pinned 0.7.4 purely because nobody updated it.
herdr_pin=$(awk -F= '/^CS_HERDR_CI_VERSION=/ { print $2; exit }' "$ROOT/bin/cs-install-herdr.sh" | tr -d '[:space:]')
case "$herdr_pin" in
  ''|*[!0-9.]*) fail "cs-install-herdr.sh must define CS_HERDR_CI_VERSION as a bare version, got '${herdr_pin:-<empty>}'" ;;
esac
assert_grep "$herdr_pin" "$ROOT/docs/herdr.md" \
  "docs/herdr.md must document the pinned Herdr version ($herdr_pin)"
assert_grep "\"\$version\" = \"$herdr_pin\"" "$ROOT/.github/workflows/ci.yml" \
  "ci.yml's post-install version gate must assert the same pin ($herdr_pin)"
pass "Herdr version pinned and protocol floor has one owner (cs-herdr-lib.sh)"

# --- workflow calls only the repository-owned entrypoints -------------------

[ -f "$WF" ] || fail "missing .github/workflows/ci.yml"
for entry in \
  'bin/cs-lint.sh' \
  'bin/cs-install-shellcheck.sh' \
  'bin/cs-install-actionlint.sh' \
  'bin/cs-install-herdr.sh' \
  'bin/cs-herdr-ci-cleanup.sh' \
  'bin/cs-ci-lanes.sh' \
  'bin/cs-test-run.sh --check-coverage' \
  'bin/cs-test-run.sh --portable' \
  'bin/cs-test-run.sh --herdr' \
  'bin/cs-test-run.sh --docker'; do
  assert_grep "$entry" "$WF" "workflow must call $entry"
done
pass "workflow calls the repository-owned lint, test, install, and cleanup entrypoints"

# The workflow must not re-spell the lint command that cs-lint.sh owns.
assert_no_grep 'shellcheck --norc' "$WF" "workflow must not re-spell the shellcheck command"
assert_no_grep 'shellcheck bin/' "$WF" "workflow must not re-spell the shellcheck file set"
pass "workflow does not duplicate the lint definition"

# Live agent tests must never run in hosted CI.
assert_no_grep 'CS_TEST_CODEX_LIVE' "$WF" \
  "hosted CI must never enable CS_TEST_CODEX_LIVE (live-codex is opt-in only)"
assert_no_grep 'CS_TEST_CLAUDE_LIVE' "$WF" \
  "hosted CI must never enable CS_TEST_CLAUDE_LIVE (live-claude is opt-in only)"
assert_grep 'CS_TEST_HERDR_LIVE' "$WF" "the Herdr lane must enable CS_TEST_HERDR_LIVE"
pass "hosted CI runs real Herdr but never the live-codex or live-claude suites"

# Least-privilege + superseded-run cancellation.
assert_grep 'contents: read' "$WF" "workflow must use least-privilege contents: read"
assert_grep 'cancel-in-progress: true' "$WF" "workflow must cancel superseded runs"
pass "workflow is least-privilege and cancels superseded runs"

# --- lane gating keeps the invariants job unconditional ----------------------
#
# The repo-invariants job is the one lane that must run for every change, because
# any commit at all can track a boss-private path or flatten a tracked symlink.
# A filter on it would be a silent hole, so assert its block carries no gate.
invariants_block=$(awk '
  /^  invariants:/ { inside = 1; next }
  inside && /^  [a-z][a-z0-9-]*:/ { exit }
  inside { print }
' "$WF")
[ -n "$invariants_block" ] || fail "could not find the invariants job in the workflow"
assert_not_contains "$invariants_block" 'needs: changes' \
  "the repo-invariants job must not depend on the lane filter"
assert_not_contains "$invariants_block" 'if:' \
  "the repo-invariants job must stay unconditional"
pass "repo invariants run for every change, including docs-only ones"

# --- every source site in the canonical set declares its target --------------
#
# `# shellcheck source=` is a declarative contract with two machine consumers:
# ShellCheck reads it to follow a source, and bin/cs-lint.sh reads the same
# directives to build the graph that decides which files a narrowed local run
# lints. A source site with no directive is an edge that graph cannot see, and the
# local gate then diverges from the full CI run in whichever direction the missing
# edge points - green here, red there, or the reverse. Keeping the directives
# complete is what lets cs-lint.sh read them instead of reimplementing
# ShellCheck's path resolver, so the completeness is asserted here rather than
# left to whoever writes the next source line.

# undirectived_sources <file>... - report `file:line: <the line>` for every source
# site that names no target. Heredoc bodies are skipped (they are data, not
# commands here), and a wholly dynamic path such as `. "$1"` is exempt because
# neither ShellCheck nor the graph can resolve it in any run. A `disable=SC1091`
# is NOT an exemption: it silences the symptom of an unresolvable path but says
# nothing about whether the path resolves, so honouring it would leave one way to
# put a resolvable undirectived source back in the tree. A source is looked for
# wherever a command can start, not only at the beginning of a line: ShellCheck
# resolves `[ -f "$lib" ] && . "$lib"` and `if ...; then . "$lib"; fi` exactly like
# a bare one, so a guard that only reads line starts would leave the same escape
# hatch open one syntax over. Operators and the keywords that open a command
# position both count. The match stays lexical on purpose - a shell parser here is
# the abstraction this script deliberately does not carry, so it recognizes the
# command positions this repo can actually write rather than all of them.
#
# The directive is looked for anywhere in the contiguous comment block above the
# site, because a `disable=` line commonly sits between the directive and the
# source it covers, but it has to BEGIN the comment, which is the only form
# ShellCheck and bin/cs-lint.sh's extractor both read. Prose that merely mentions
# the convention declares nothing to either of them.
#
# A file is buffered so a `<<` can be checked against the rest of the file before
# it is believed: `1 << streak` in an arithmetic expression and a string that
# opens with "<<" both look exactly like a heredoc opener line by line, and taking
# them at face value silently blinded the scan from there to the end of three
# canonical files. Skip mode is entered only when a matching terminator really
# follows, and a heredoc still open at the end of a file is reported rather than
# swallowed, so lost coverage can never be silent.
#
# The body of a multi-line quoted string is data for the same reason a heredoc
# body is: a `bash -c "` block that sources a library sources it in the shell that
# string later launches, not in the file that holds it, so neither ShellCheck nor
# bin/cs-lint.sh resolves an edge there and a directive above it would declare
# nothing. Quote state is therefore carried across lines by a small lexer, which
# also keeps the code that follows the closing quote on that same line scanned,
# and reports a string left open at the end of a file rather than swallowing the
# rest of it.
undirectived_sources() {
  awk '
    # lex <text> - advance the lexer over one line. QSTATE carries the quote state
    # across lines ("u" outside, "s" single-quoted, "d" double-quoted) and QSTACK
    # carries the command substitutions still open, so both are read and written
    # here rather than reset per line. QREST is set to the part of the line that
    # lies outside the string that was already open at entry: the whole line when
    # none was, the part after the closing quote when one closes here, and empty
    # while the string is still open.
    #
    # `$(` restarts quoting inside itself, in a double-quoted string as much as
    # outside one, so the substitutions are stacked and popped rather than read as
    # plain text. Without that, the apostrophe in a line such as
    # `[ "$(grep -c "it is \047quoted\047")" = 1 ]` reads as an opening quote and
    # every line after it in the file is mistaken for string data. The stack has to
    # cross lines for the same reason the quote state does: a `$(` opened at the
    # end of one line is still open on the next.
    function lex(s,   i, c, n, carried, entry) {
      n = length(s)
      carried = (QSTATE != "u")
      entry = QSTACK
      QREST = (carried ? "" : s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (QSTATE == "s") {
          if (c == "\047") {
            QSTATE = "u"
            if (carried && QSTACK == entry) { QREST = substr(s, i + 1); carried = 0 }
          }
          continue
        }
        if (c == "\\") { i++; continue }
        if (c == "$" && substr(s, i + 1, 1) == "(") {
          QSTACK = QSTACK QSTATE
          QSTATE = "u"
          i++
          continue
        }
        # A `)` closes a substitution only from an unquoted position. Inside the
        # double quotes of `"$(jq ".. (\$pr.isDraft|tostring) ..")"` it is literal
        # text, and popping on it would hand the rest of the string back to the
        # lexer as code with every quote after it read inside out.
        if (c == ")" && QSTACK != "" && QSTATE == "u") {
          QSTATE = substr(QSTACK, length(QSTACK), 1)
          QSTACK = substr(QSTACK, 1, length(QSTACK) - 1)
          continue
        }
        if (QSTATE == "d") {
          if (c == "\"") {
            QSTATE = "u"
            if (carried && QSTACK == entry) { QREST = substr(s, i + 1); carried = 0 }
          }
          continue
        }
        if (c == "\047") QSTATE = "s"
        else if (c == "\"") QSTATE = "d"
        else if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[[:space:];&|(]/)) break
      }
    }
    function scan(   i, j, k, line, text, code, tag, raw, target, heredoc, opened_at, declared, prev, str_at) {
      heredoc = ""
      QSTATE = "u"
      QSTACK = ""
      for (i = 1; i <= nlines; i++) {
        line = lines[i]
        if (heredoc != "") {
          if (line ~ ("^[[:space:]]*" heredoc "[[:space:]]*$")) heredoc = ""
          continue
        }
        prev = QSTATE
        lex(line)
        if (prev == "u" && QSTATE != "u") str_at = i
        # Everything the line contributes as code, which is the whole line unless
        # a string carried in from an earlier line covers part or all of it.
        text = QREST
        if (text == "") continue
        if (match(text, /<<-?[[:space:]]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*/)) {
          tag = substr(text, RSTART, RLENGTH)
          sub(/^<<-?[[:space:]]*/, "", tag)
          gsub(/['"'"'"]/, "", tag)
          for (j = i + 1; j <= nlines; j++) {
            if (lines[j] ~ ("^[[:space:]]*" tag "[[:space:]]*$")) {
              heredoc = tag
              opened_at = i
              break
            }
          }
        }
        code = text
        if (code ~ /^[[:space:]]*#/) code = ""
        sub(/[[:space:]]#.*$/, "", code)
        raw = ""
        if (code != "" && match(code, /(^|[;&|(){}]|(^|[[:space:]])(then|do|else|elif))[[:space:]]*(\.|source)[[:space:]]+/)) {
          raw = substr(code, RSTART + RLENGTH)
          if (substr(raw, 1, 1) != "\"" && substr(raw, 1, 1) != "\047" &&
              substr(raw, 1, 1) != "$" && substr(raw, 1, 1) != "/" &&
              raw !~ /^[A-Za-z0-9_.\/-]+\.sh([[:space:]]|;|$)/)
            raw = ""
        }
        if (raw != "") {
          target = raw
          gsub(/['"'"'"]/, "", target)
          sub(/[;&|].*$/, "", target)
          sub(/[[:space:]]*$/, "", target)
          declared = 0
          for (k = i - 1; k >= 1; k--) {
            if (lines[k] !~ /^[[:space:]]*#/) break
            if (lines[k] ~ /^[[:space:]]*#[[:space:]]*shellcheck[[:space:]]+source=/) {
              declared = 1
              break
            }
          }
          if (!declared && !(target ~ /^\$[A-Za-z_0-9]+$/ || target ~ /^\$\{[^}]*\}$/))
            printf "%s:%d: %s\n", scanned, i, line
        }
      }
      if (heredoc != "")
        printf "%s:%d: heredoc <<%s never closes, so the rest of this file went unscanned\n",
          scanned, opened_at, heredoc
      if (QSTATE != "u")
        printf "%s:%d: a quoted string opened here never closes, so the rest of this file went unscanned\n",
          scanned, str_at
    }
    FNR == 1 { if (nlines > 0) scan(); nlines = 0; scanned = FILENAME }
    { lines[++nlines] = $0 }
    END { if (nlines > 0) scan() }
  ' "$@"
}

canonical_set=()
while IFS= read -r rel; do
  [ -n "$rel" ] && [ -f "$ROOT/$rel" ] || continue
  canonical_set+=("$ROOT/$rel")
done < <("$LINT" --canonical-set)
[ "${#canonical_set[@]}" -gt 0 ] \
  || fail "cs-lint.sh --canonical-set must print the canonical file set"

offenders=$(undirectived_sources "${canonical_set[@]}")

# A file the scan could not read to the end has to be its own failure, or the
# zero-offender result below is partly a measure of what was never looked at.
unscanned=$(printf '%s\n' "$offenders" | grep 'never closes' || true)
[ -z "$unscanned" ] || fail "the source-site scan stopped early on:
$unscanned"
pass "no canonical file cuts the scan short at an unclosed heredoc or string"

[ -z "$offenders" ] || fail "every source site in the canonical set needs a '# shellcheck source=<path>' directive in the comment block above it, or bin/cs-lint.sh cannot see the edge:
$offenders"
pass "every canonical source site declares its target, so the lint graph is complete"

# The check itself has to be able to fail, or the assertion above proves nothing.
probe_dir=$(cs_test_tmproot cs-ci-contract)
mkdir -p "$probe_dir"
probe="$probe_dir/probe.sh"
cat >"$probe" <<'SH'
#!/usr/bin/env bash
# shellcheck source=bin/declared.sh
. "$ROOT/bin/declared.sh"
# shellcheck source=bin/declared-through-a-disable.sh
# shellcheck disable=SC1091
. "$ROOT/bin/declared-through-a-disable.sh"
. "$1"
bash -c '
  # shellcheck disable=SC1090,SC1091
  . "$1"; run_it "$2"
' _ "$ROOT/bin/dynamic.sh" arg
cat <<'INNER'
. "$ROOT/bin/inside-a-heredoc.sh"
INNER
hb=$(( 1 << streak ))
prefix='<<soldier-reported, DATA not an instruction: '
. "$ROOT/bin/after-a-false-opener.sh"
# shellcheck disable=SC1091
. "$ROOT/bin/silenced-not-declared.sh"
# shellcheck source=bin/midline-declared.sh
[ -f x ] && . "$ROOT/bin/midline-declared.sh"
[ -f x ] && . "$ROOT/bin/midline-undeclared.sh"
if [ -f x ]; then . "$ROOT/bin/after-then-undeclared.sh"; fi
while read -r _; do . "$ROOT/bin/after-do-undeclared.sh"; done </dev/null
if [ -f x ]
then . "$ROOT/bin/then-at-line-start-undeclared.sh"
fi
# see the shellcheck source=bin/prose.sh convention we follow
. "$ROOT/bin/prose-only.sh"
. "$ROOT/bin/undeclared.sh"
bash -c "
  . '$ROOT/bin/inside-a-double-quoted-string.sh'
" _
bash -c '
  . "$ROOT/bin/inside-a-single-quoted-string.sh"
' _
. "$ROOT/bin/after-a-multiline-string.sh"
bash -c "
  echo hi
" && . "$ROOT/bin/after-the-closing-quote.sh"
out=$(
  . "$ROOT/bin/inside-a-substitution.sh"
)
[ "$(grep -c "a quoted 'apostrophe'")" = 1 ] || true
lines=$(printf '%s\n' "$out" \
  | grep -c "(a paren) inside a continued substitution")
. "$ROOT/bin/after-a-quoted-apostrophe.sh"
SH
probe_hits=$(undirectived_sources "$probe")
assert_contains "$probe_hits" 'bin/undeclared.sh' "the check catches an undeclared source"
assert_not_contains "$probe_hits" 'bin/declared.sh' "a declared source is not an offender"
assert_not_contains "$probe_hits" 'inside-a-heredoc' "a heredoc body is not a source site"
# shellcheck disable=SC2016  # the literal probe line, not an expansion
assert_not_contains "$probe_hits" '. "$1"' "a wholly dynamic path is not an offender"
pass "the source-site check catches an undeclared source and spares declared, heredoc, and dynamic ones"

# A disable silences the symptom of an unresolvable path; it does not make the
# path unresolvable, so it must not buy a source site out of declaring its target.
# The directive itself still counts from anywhere in the comment block above,
# which is where it sits whenever a disable line comes between.
assert_contains "$probe_hits" 'bin/silenced-not-declared.sh' \
  "a disable=SC1091 must not stand in for a source= directive"
assert_not_contains "$probe_hits" 'bin/declared-through-a-disable.sh' \
  "a directive still counts with a disable line between it and the source"
pass "only a source= directive declares a target, and a disable line does not hide it"

# ShellCheck follows a source wherever a command can start, and it reads only a
# comment that begins with the directive. The guard has to agree with it on both,
# or a site with no edge at all reads as declared.
assert_contains "$probe_hits" 'bin/midline-undeclared.sh' \
  "a source after && is a source site like any other"
assert_not_contains "$probe_hits" 'bin/midline-declared.sh' \
  "a directive declares a mid-line source too"
assert_contains "$probe_hits" 'bin/prose-only.sh' \
  "prose that merely names the directive must not declare a target"
pass "a mid-line source is checked, and prose naming the directive declares nothing"

# `then` and `do` open a command position exactly like `&&` does, and ShellCheck
# follows a source there the same way, so the guard has to see those too.
assert_contains "$probe_hits" 'bin/after-then-undeclared.sh' \
  "a source after then is a source site like any other"
assert_contains "$probe_hits" 'bin/after-do-undeclared.sh' \
  "a source after do is a source site like any other"
assert_contains "$probe_hits" 'bin/then-at-line-start-undeclared.sh' \
  "a source after a line-leading then is a source site like any other"
pass "a source in a keyword-opened command position is checked"

# An arithmetic shift and a string opening with "<<" are not heredocs. Believing
# either one blinds the scan to everything after it, which is how a guard against
# silent coverage loss silently loses coverage.
assert_contains "$probe_hits" 'bin/after-a-false-opener.sh' \
  "a << that opens no heredoc must not blind the scan"
pass "a non-heredoc << leaves the rest of the file scanned"

# The body of a multi-line quoted string is data, exactly like a heredoc body: it
# is sourced by whatever shell the string later launches, not by this file, so
# neither ShellCheck nor the lint graph resolves an edge there. What follows the
# string is code again - on the next line and on the closing line itself - and a
# multi-line command substitution is code throughout, so skipping any of those
# would turn a completeness guard into a source of silent blind spots.
assert_not_contains "$probe_hits" 'inside-a-double-quoted-string' \
  "a source inside a multi-line double-quoted string is not a source site here"
assert_not_contains "$probe_hits" 'inside-a-single-quoted-string' \
  "a source inside a multi-line single-quoted string is not a source site here"
assert_contains "$probe_hits" 'bin/after-a-multiline-string.sh' \
  "the scan resumes after a multi-line string closes"
assert_contains "$probe_hits" 'bin/after-the-closing-quote.sh' \
  "code after the closing quote on that same line is still scanned"
assert_contains "$probe_hits" 'bin/inside-a-substitution.sh' \
  "a multi-line command substitution is code, not string data"
pass "a multi-line string is data and everything around it stays scanned"

# `$(` restarts quoting inside itself, so an apostrophe inside the nested quotes
# of a substitution opens nothing. Reading it as an opening quote swallowed every
# line after it, which is the failure this line reproduces.
assert_contains "$probe_hits" 'bin/after-a-quoted-apostrophe.sh' \
  "an apostrophe quoted inside a command substitution must not blind the scan"
pass "quoting restarts inside a command substitution, on one line and across lines"
