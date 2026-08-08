#!/usr/bin/env bash
# Behavior (portable): cs-lint.sh lints only the canonical-set files a branch
# changed, and still lints the FULL canonical set wherever a local diff cannot
# stand in for coverage - in CI, on the default branch, on a branch with no
# merge-base, and in a checkout whose git toplevel is some outer repository. The
# selection is a local-speed optimization, so the cases that prove it cannot
# weaken the gate matter more than the happy path.
#
# The fixture is a throwaway git repo holding a copy of cs-lint.sh (the script
# resolves its root from its own location) and a fake `shellcheck` that records
# the exact file list it was handed.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/cs-lint.sh"
PINNED=$("$LINT" --required-version)
[ -n "$PINNED" ] || fail "cs-lint.sh --required-version must print a version"

TMP=$(cs_test_tmproot cs-lint)
REPO="$TMP/repo"
FAKEBIN=$(cs_fakebin "$TMP")
ARGS="$TMP/shellcheck-args"

# The fake shellcheck answers the version pin, then records the file list of a
# lint run. It never writes the args file on --version, so an absent file means
# no lint run happened at all.
cat >"$FAKEBIN/shellcheck" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: %s\n' "$PINNED"
  exit 0
fi
: >"$ARGS"
for arg in "\$@"; do
  [ "\$arg" = --norc ] && continue
  printf '%s\n' "\$arg" >>"$ARGS"
done
exit 0
SH
chmod +x "$FAKEBIN/shellcheck"

cs_git_identity

# A locale whose collation is not byte order, so the fixture reproduces the trap
# that once dropped cs-lint.sh from its own change set: `sort` runs under C while
# `comm` runs under the ambient locale, and en_US.UTF-8 orders "bin/..." before
# "README.md" where C orders it after. Empty on a machine with no such locale, in
# which case the cases still run, just under the ambient collation.
COLLATE_LOCALE=$(locale -a 2>/dev/null | grep -ix -m1 'en_US.utf-*8' || true)

# --- fixture repo -------------------------------------------------------------
#
# origin/main is created as a plain local ref: the selection must work from local
# git alone, with no fetch and no remote.

mkdir -p "$REPO/bin" "$REPO/tests" "$REPO/docs"
git -C "$REPO" init -q
git -C "$REPO" symbolic-ref HEAD refs/heads/main
cp "$LINT" "$REPO/bin/cs-lint.sh"
chmod +x "$REPO/bin/cs-lint.sh"
for f in bin/kept.sh bin/edited.sh bin/removed.sh bin/lib-one.sh bin/lib-two.sh \
  bin/shared-lib.sh tests/kept.test.sh tests/edited.test.sh tests/lib.sh; do
  printf '#!/usr/bin/env bash\ntrue\n' >"$REPO/$f"
done
printf 'notes\n' >"$REPO/docs/notes.md"
# README.md is the collation tripwire: it must be a changed non-canonical file
# whose position relative to bin/ and tests/ differs between C and UTF-8 order.
printf 'fixture\n' >"$REPO/README.md"

# A sourced library has to ride along with the file that sources it, or ShellCheck
# reports SC1091 against a line the full-set run resolves silently. The fixture
# declares a two-deep chain, an indented directive carrying a trailing note, and
# one out-of-set source, so the closure is exercised the way the repo actually
# writes them. bin/shared-lib.sh is the reverse case: two canonical files source
# it, and a finding caused by changing it would be reported in them, not in it.
cat >>"$REPO/bin/edited.sh" <<'SH'
# shellcheck source=bin/lib-one.sh
. "$(dirname "$0")/lib-one.sh"
# shellcheck source=/dev/null
. "$SOMEWHERE_ELSE"
SH
cat >>"$REPO/bin/lib-one.sh" <<'SH'
# shellcheck source=bin/lib-two.sh
. "$(dirname "$0")/lib-two.sh"
SH
cat >>"$REPO/tests/edited.test.sh" <<'SH'
  # shellcheck source=tests/lib.sh  # shared primitives
  . "$(dirname "$0")/lib.sh"
SH
cat >>"$REPO/bin/kept.sh" <<'SH'
# shellcheck source=bin/shared-lib.sh
. "$(dirname "$0")/shared-lib.sh"
# shellcheck source=bin/lib-one.sh
. "$(dirname "$0")/lib-one.sh"
SH
cat >>"$REPO/tests/kept.test.sh" <<'SH'
# shellcheck source=bin/shared-lib.sh
. "$(dirname "$0")/../bin/shared-lib.sh"
SH
git -C "$REPO" add -A
git -C "$REPO" commit -qm initial
git -C "$REPO" update-ref refs/remotes/origin/main HEAD

# run_lint [VAR=VALUE]... [path]... - run the fixture's cs-lint.sh. Leading
# VAR=VALUE tokens become its environment and the rest are passed through as
# paths. Both CI markers are cleared first, so a suite running inside hosted CI
# still exercises the local selection path unless the case sets one back.
# Echoes stderr; the file list ShellCheck received lands in $ARGS.
run_lint() {
  local envs=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      *=*) envs+=("$1"); shift ;;
      *) break ;;
    esac
  done
  rm -f "$ARGS"
  (
    cd "$REPO" || exit 1
    PATH="$FAKEBIN:$PATH" env -u CI -u GITHUB_ACTIONS \
      ${COLLATE_LOCALE:+LC_ALL="$COLLATE_LOCALE"} \
      ${envs[@]+"${envs[@]}"} bin/cs-lint.sh "$@" 2>&1
  )
}

linted() {
  [ -f "$ARGS" ] || return 0
  LC_ALL=C sort "$ARGS" | tr '\n' ' '
}

# The fixture's whole canonical set as it stands on disk right now, in the order
# `linted` reports it. Derived rather than spelled out, so a full run is compared
# against every canonical file that exists at that point in the fixture's life.
full_set() {
  (
    cd "$REPO" || exit 1
    printf '%s\n' bin/*.sh tests/*.sh | LC_ALL=C sort | tr '\n' ' '
  )
}

# --- the default branch always lints the full set -----------------------------

out=$(run_lint)
[ "$(linted)" = "$(full_set)" ] || fail "on the default branch cs-lint must lint the full set, got: $(linted)"
assert_contains "$out" 'full canonical set (on the default branch main)' \
  'the default-branch run names its reason'
pass 'the default branch lints the full canonical set'

# --- a feature branch lints only what it changed ------------------------------

git -C "$REPO" checkout -q -b feature
printf 'false\n' >>"$REPO/bin/edited.sh"
printf 'more notes\n' >>"$REPO/docs/notes.md"
printf 'more fixture\n' >>"$REPO/README.md"
git -C "$REPO" rm -q "$REPO/bin/removed.sh"
git -C "$REPO" add -A
git -C "$REPO" commit -qm 'edit one script, one doc, drop one script'
# An uncommitted edit and a brand-new untracked script must both be selected.
printf '# edited in the working tree\n' >>"$REPO/tests/edited.test.sh"
printf '#!/usr/bin/env bash\ntrue\n' >"$REPO/bin/untracked.sh"

out=$(run_lint)
got=$(linted)
[ "$got" = 'bin/edited.sh bin/lib-one.sh bin/lib-two.sh bin/untracked.sh tests/edited.test.sh tests/lib.sh ' ] \
  || fail "a feature branch must lint its changed canonical files and their sourced closure, got: $got"
assert_contains "$out" 'linting 3 changed file(s) plus 3 source-linked file(s) since origin/main' \
  'the selection run reports its counts and base'
pass 'a feature branch lints its changed canonical files, including uncommitted and untracked ones'
pass 'the sourced closure rides along, transitively and through an indented directive'
# bin/kept.sh sources bin/lib-one.sh, which rode along here as an unchanged
# library. Pulling in a library's consumers only makes sense for a library this
# branch actually changed, so kept.sh must stay out.
case "$got" in
  *bin/kept.sh*) fail 'an unchanged library must not drag in its own consumers' ;;
esac
pass 'consumers of an unchanged, merely sourced library stay out of the selection'

# The exclusions the selection depends on, stated as their own failures.
case "$got" in
  *bin/kept.sh*) fail 'an unchanged canonical file must not be linted' ;;
  *docs/notes.md*) fail 'a changed non-canonical file must never be linted' ;;
  *bin/removed.sh*) fail 'a deleted file must not be handed to ShellCheck' ;;
  */dev/null*) fail 'a source outside the canonical set must not be linted' ;;
esac
pass 'unchanged, non-canonical, deleted, and out-of-set files stay out of the selection'

# --- CI always lints the full set ---------------------------------------------

out=$(run_lint CI=true)
[ "$(linted)" = "$(full_set)" ] || fail "CI=true must lint the full canonical set, got: $(linted)"
assert_contains "$out" 'full canonical set (CI)' 'the CI run names its reason'
out=$(run_lint GITHUB_ACTIONS=true)
[ "$(linted)" = "$(full_set)" ] || fail "GITHUB_ACTIONS=true must lint the full canonical set, got: $(linted)"
pass 'CI lints the full canonical set regardless of the local diff'

# --- no merge-base falls back to the full set, never to nothing ---------------

git -C "$REPO" checkout -q --orphan lonely
git -C "$REPO" commit -q --allow-empty -m 'unrelated history'
out=$(run_lint)
[ "$(linted)" = "$(full_set)" ] || fail "an unrelated history must lint the full set, got: $(linted)"
assert_contains "$out" 'no merge-base with origin/main' 'the fallback names its reason'
git -C "$REPO" checkout -q feature

git -C "$REPO" update-ref -d refs/remotes/origin/main
out=$(run_lint)
[ "$(linted)" = "$(full_set)" ] || fail "a missing origin/main must lint the full set, got: $(linted)"
assert_contains "$out" 'no merge-base with origin/main' 'a missing base ref names the same reason'
git -C "$REPO" update-ref refs/remotes/origin/main main
pass 'a branch with no merge-base falls back to the full canonical set'

# --- a checkout nested inside another repo falls back to the full set ----------
#
# git names diff paths from the repository toplevel while the canonical globs are
# relative to the script's own root, so a checkout sitting inside an outer repo
# has no shared path base and the intersection would come back empty. That must
# lint everything, never nothing.

NESTED="$TMP/nested"
mkdir -p "$NESTED/tools/cs/bin" "$NESTED/tools/cs/tests"
git -C "$NESTED" init -q
# Any branch but the default one, so the toplevel reason is what this case proves.
git -C "$NESTED" symbolic-ref HEAD refs/heads/nested-feature
cp "$LINT" "$NESTED/tools/cs/bin/cs-lint.sh"
chmod +x "$NESTED/tools/cs/bin/cs-lint.sh"
printf '#!/usr/bin/env bash\ntrue\n' >"$NESTED/tools/cs/bin/kept.sh"
printf '#!/usr/bin/env bash\ntrue\n' >"$NESTED/tools/cs/tests/kept.test.sh"
git -C "$NESTED" add -A
git -C "$NESTED" commit -qm initial
# A merge-base and a real canonical-set edit both exist, so an empty selection
# here could only come from the mismatched path bases.
git -C "$NESTED" update-ref refs/remotes/origin/main HEAD
printf 'false\n' >>"$NESTED/tools/cs/bin/kept.sh"

rm -f "$ARGS"
out=$(
  cd "$NESTED/tools/cs" || exit 1
  PATH="$FAKEBIN:$PATH" env -u CI -u GITHUB_ACTIONS \
    ${COLLATE_LOCALE:+LC_ALL="$COLLATE_LOCALE"} \
    bin/cs-lint.sh 2>&1
)
nested_full=$(
  cd "$NESTED/tools/cs" || exit 1
  printf '%s\n' bin/*.sh tests/*.sh | LC_ALL=C sort | tr '\n' ' '
)
[ "$(linted)" = "$nested_full" ] \
  || fail "a checkout nested inside another repo must lint the full set, got: $(linted)"
assert_contains "$out" 'the repository toplevel is not' 'the nested-checkout run names its reason'
pass 'a checkout whose git toplevel is an outer repository lints the full canonical set'

# --- explicit paths bypass the selection entirely -----------------------------

out=$(run_lint bin/kept.sh)
[ "$(linted)" = 'bin/kept.sh ' ] \
  || fail "explicit paths must lint exactly what was named, got: $(linted)"
assert_not_contains "$out" 'source-linked file(s)' \
  'an explicit-path run does not report a selection'
out=$(run_lint CI=true bin/kept.sh)
[ "$(linted)" = 'bin/kept.sh ' ] \
  || fail "explicit paths must bypass the CI full-set path too, got: $(linted)"
pass 'explicit paths bypass the change selection'

# --- a branch that changed no canonical file lints nothing --------------------

git -C "$REPO" checkout -q -b docs-only feature
rm -f "$REPO/bin/untracked.sh"
git -C "$REPO" checkout -q -- tests/edited.test.sh
git -C "$REPO" update-ref refs/remotes/origin/main HEAD
printf 'docs only\n' >>"$REPO/docs/notes.md"

out=$(run_lint)
expect_code 0 "$?" 'a change set with no canonical file exits 0'
[ ! -f "$ARGS" ] || fail "ShellCheck must not run when no canonical file changed, got: $(linted)"
assert_contains "$out" 'no canonical-set file changed since origin/main' \
  'the empty-selection run says so'
pass 'a change set with no canonical file lints nothing and exits 0'

# --- a changed library pulls in the files that source it ----------------------
#
# ShellCheck blames a library's broken contract on the file that sources it, so a
# branch that only touches bin/shared-lib.sh has to lint both of its consumers -
# otherwise the narrowed run goes green where CI goes red. Those consumers then
# need their own sourced libraries as inputs, or narrowing invents SC1091 in them.

git -C "$REPO" checkout -q -b shared-lib
git -C "$REPO" checkout -q -- docs/notes.md
printf 'true\n' >>"$REPO/bin/shared-lib.sh"

out=$(run_lint)
got=$(linted)
[ "$got" = 'bin/kept.sh bin/lib-one.sh bin/lib-two.sh bin/shared-lib.sh tests/kept.test.sh ' ] \
  || fail "a changed library must lint its consumers and their own sourced libraries, got: $got"
assert_contains "$out" 'linting 1 changed file(s) plus 4 source-linked file(s) since origin/main' \
  'the reverse closure is counted in the summary'
pass 'a changed library pulls in every canonical file that sources it'
pass 'a pulled-in consumer brings its own sourced libraries along'
