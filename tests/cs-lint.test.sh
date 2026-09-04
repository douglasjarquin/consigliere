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

cat >"$FAKEBIN/actionlint" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -version ]; then
  printf '1.7.12\n'
  exit 0
fi
exit 0
SH
chmod +x "$FAKEBIN/actionlint"

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

mkdir -p "$REPO/bin" "$REPO/tests" "$REPO/docs" "$REPO/.github/workflows"
cat >"$REPO/.github/workflows/ci.yml" <<'YAML'
name: CI
on: push
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
YAML
git -C "$REPO" init -q
git -C "$REPO" symbolic-ref HEAD refs/heads/main
cp "$LINT" "$REPO/bin/cs-lint.sh"
cp "$ROOT/bin/cs-lint-workflows.sh" "$REPO/bin/cs-lint-workflows.sh"
chmod +x "$REPO/bin/cs-lint.sh" "$REPO/bin/cs-lint-workflows.sh"
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
# writes them. bin/shared-lib.sh is the reverse case: several canonical files
# source it, and a finding caused by changing it would be reported in them, not
# in it.
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
mkdir -p "$NESTED/tools/cs/bin" "$NESTED/tools/cs/tests" "$NESTED/tools/cs/.github/workflows"
cat >"$NESTED/tools/cs/.github/workflows/ci.yml" <<'YAML'
name: CI
on: push
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
YAML
git -C "$NESTED" init -q
# Any branch but the default one, so the toplevel reason is what this case proves.
git -C "$NESTED" symbolic-ref HEAD refs/heads/nested-feature
cp "$LINT" "$NESTED/tools/cs/bin/cs-lint.sh"
cp "$ROOT/bin/cs-lint-workflows.sh" "$NESTED/tools/cs/bin/cs-lint-workflows.sh"
chmod +x "$NESTED/tools/cs/bin/cs-lint.sh" "$NESTED/tools/cs/bin/cs-lint-workflows.sh"
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

# --- a deleted library still pulls in the consumers it left behind ------------
#
# Deleting a library is a change its consumers are judged on: a full run reports
# SC1091 in every file still sourcing it. The deleted path seeds the reverse pass
# and then has to come back out, since ShellCheck cannot read a file that is gone.

git -C "$REPO" checkout -q -b drop-shared-lib
git -C "$REPO" checkout -q -- bin/shared-lib.sh
git -C "$REPO" rm -q "$REPO/bin/shared-lib.sh"

out=$(run_lint)
got=$(linted)
[ "$got" = 'bin/kept.sh bin/lib-one.sh bin/lib-two.sh tests/kept.test.sh ' ] \
  || fail "a deleted library must lint the consumers it left behind, got: $got"
assert_not_contains "$out" 'nothing to lint' 'a deleted library is not an empty change set'
assert_contains "$out" 'linting 0 changed file(s) plus 4 source-linked file(s) since origin/main' \
  'the deleted path is counted as source-linked, never as an input'
pass 'a deleted library lints the canonical files that still source it, and is not linted itself'

# --- a renamed library still pulls in the consumer left pointing at it ---------
#
# A rename is a deletion of the old path as far as a stale directive is concerned,
# but git reports a move as one entry naming only the destination, so the path the
# branch moved away from has to be recovered or the forgotten consumer is missed.

git -C "$REPO" reset -q --hard
git -C "$REPO" checkout -q -b rename-shared-lib
git -C "$REPO" mv bin/shared-lib.sh bin/renamed-lib.sh
# Only one of the two consumers is updated; tests/kept.test.sh is left pointing at
# a path that no longer exists, which is what a full run fails on.
sed 's|bin/shared-lib.sh|bin/renamed-lib.sh|' "$REPO/bin/kept.sh" >"$TMP/kept.sh"
mv "$TMP/kept.sh" "$REPO/bin/kept.sh"

out=$(run_lint)
got=$(linted)
[ "$got" = 'bin/kept.sh bin/lib-one.sh bin/lib-two.sh bin/renamed-lib.sh tests/kept.test.sh ' ] \
  || fail "a renamed library must lint the consumer left pointing at its old path, got: $got"
assert_contains "$out" 'linting 2 changed file(s) plus 3 source-linked file(s) since origin/main' \
  'the path renamed away from is counted through its consumers'
pass 'a renamed library pulls in the consumer whose directive was never updated'

# --- a deleted path written back unstaged is still linted ---------------------
#
# git reports such a path as deleted (it is gone from the index) while the file
# sits on disk with brand-new content, so the deletion seed must not double as
# permission to drop it: a full run lints whatever the canonical globs find on
# disk, and this file is exactly what a branch changed.

git -C "$REPO" reset -q --hard
git -C "$REPO" checkout -q -b recreate-shared-lib
git -C "$REPO" rm -q "$REPO/bin/shared-lib.sh"
git -C "$REPO" commit -qm 'remove the shared library'
printf '#!/usr/bin/env bash\ntrue\n' >"$REPO/bin/shared-lib.sh"

out=$(run_lint)
got=$(linted)
[ "$got" = 'bin/kept.sh bin/lib-one.sh bin/lib-two.sh bin/shared-lib.sh tests/kept.test.sh ' ] \
  || fail "a deleted path recreated on disk must still be linted, got: $got"
assert_contains "$out" 'linting 1 changed file(s) plus 4 source-linked file(s) since origin/main' \
  'a path that is both deleted and present counts once, as changed'
pass 'a canonical path removed from the index but present on disk is linted'

# --- ShellCheck installer + missing-tool errors --------------------------------

INSTALLER="$ROOT/bin/cs-install-shellcheck.sh"

SHELLCHECK_SHA_LINUX_X86_64=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
SHELLCHECK_SHA_LINUX_AARCH64=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588
SHELLCHECK_SHA_DARWIN_X86_64=3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6
SHELLCHECK_SHA_DARWIN_AARCH64=56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79

cs_install_stub_uname() {
  local fakebin=$1
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf '%s\n' "${CS_TEST_UNAME_S:-Linux}" ;;
  -m) printf '%s\n' "${CS_TEST_UNAME_M:-x86_64}" ;;
  *) printf '%s\n' "${CS_TEST_UNAME_S:-Linux}" ;;
esac
SH
  chmod +x "$fakebin/uname"
}

cs_install_stub_curl() {
  local fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "${CURL_COUNT:-}" ] || count=$(cat "$CURL_COUNT")
count=$((count + 1))
[ -z "${CURL_COUNT:-}" ] || printf '%s\n' "$count" > "$CURL_COUNT"
url=
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out=$2
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url=$1
      shift
      ;;
  esac
done
[ -z "${CURL_URL_LOG:-}" ] || printf '%s\n' "$url" >> "$CURL_URL_LOG"
fail_until=${CURL_FAIL_UNTIL:-0}
[ "$count" -gt "$fail_until" ] || exit 22
: > "$out"
exit 0
SH
  chmod +x "$fakebin/curl"
}

cs_install_stub_hasher() {
  local fakebin=$1 name=$2
  cat > "$fakebin/$name" <<'SH'
#!/usr/bin/env bash
self=${0##*/}
if [ -n "${HASHER_LOG:-}" ]; then
  printf '%s\n' "$self $*" >> "$HASHER_LOG"
fi
file=$1
if [ "$self" = shasum ]; then
  algo=
  file=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -a)
        algo=$2
        shift 2
        ;;
      *)
        file=$1
        shift
        ;;
    esac
  done
  [ "$algo" = 256 ] || exit 1
fi
printf '%s  %s\n' "${SHA256_STUB_HASH:?}" "$file"
SH
  chmod +x "$fakebin/$name"
}

cs_install_stub_tar_shellcheck() {
  local fakebin=$1
  cat > "$fakebin/tar" <<SH
#!/usr/bin/env bash
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = "-C" ]; then
    mkdir -p "\$2/shellcheck-v${PINNED}"
    cat > "\$2/shellcheck-v${PINNED}/shellcheck" <<EOF
#!/usr/bin/env bash
printf 'ShellCheck - shell script analysis tool\nversion: ${PINNED}\n'
EOF
    chmod +x "\$2/shellcheck-v${PINNED}/shellcheck"
    exit 0
  fi
  shift
done
exit 2
SH
  chmod +x "$fakebin/tar"
}

cs_install_stub_sleep() {
  local fakebin=$1
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
}

test_installer_retries_transient_download_failure() {
  local tmp fakebin destination out
  tmp=$(cs_test_tmproot cs-shellcheck-download)
  fakebin=$(cs_fakebin "$tmp")
  destination="$tmp/bin"

  cs_install_stub_uname "$fakebin"
  cs_install_stub_curl "$fakebin"
  cs_install_stub_hasher "$fakebin" sha256sum
  cs_install_stub_tar_shellcheck "$fakebin"
  cs_install_stub_sleep "$fakebin"

  out=$(CURL_COUNT="$tmp/curl-count" CURL_FAIL_UNTIL=3 \
    SHA256_STUB_HASH="$SHELLCHECK_SHA_LINUX_X86_64" \
    CS_TEST_UNAME_S=Linux CS_TEST_UNAME_M=x86_64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) \
    || fail "installer did not recover from a transient download failure"$'\n'"$out"
  [ "$(cat "$tmp/curl-count")" -eq 4 ] || fail "installer did not recover after three failed downloads"
  assert_contains "$out" "download attempt 3 failed; retrying" "installer did not disclose its third retry"
  [ -x "$destination/shellcheck" ] || fail "installer did not install ShellCheck after retrying"
  pass "ShellCheck installer retries a transient download failure"
}

test_installer_selects_platform_archive_url_and_checksum() {
  local tmp fakebin destination out url_log uname_s uname_m archive sha
  tmp=$(cs_test_tmproot cs-shellcheck-platform)
  fakebin=$(cs_fakebin "$tmp")
  destination="$tmp/bin"
  url_log="$tmp/curl-url.log"

  cs_install_stub_uname "$fakebin"
  cs_install_stub_curl "$fakebin"
  cs_install_stub_hasher "$fakebin" sha256sum
  cs_install_stub_tar_shellcheck "$fakebin"
  cs_install_stub_sleep "$fakebin"

  while IFS=$'\t' read -r uname_s uname_m archive sha; do
    [ -n "$uname_s" ] || continue
    rm -rf "$destination"
    : > "$url_log"
    out=$(CURL_URL_LOG="$url_log" SHA256_STUB_HASH="$sha" \
      CS_TEST_UNAME_S="$uname_s" CS_TEST_UNAME_M="$uname_m" \
      PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) \
      || fail "installer failed for ${uname_s}/${uname_m}"$'\n'"$out"
    assert_contains "$(cat "$url_log")" "$archive" \
      "installer did not download $archive for ${uname_s}/${uname_m}"
    assert_contains "$(cat "$url_log")" \
      "https://github.com/koalaman/shellcheck/releases/download/v${PINNED}/${archive}" \
      "installer used the wrong URL for ${uname_s}/${uname_m}"
    [ -x "$destination/shellcheck" ] || fail "installer did not install ShellCheck for ${uname_s}/${uname_m}"
  done <<EOF
Linux	x86_64	shellcheck-v${PINNED}.linux.x86_64.tar.xz	$SHELLCHECK_SHA_LINUX_X86_64
Linux	amd64	shellcheck-v${PINNED}.linux.x86_64.tar.xz	$SHELLCHECK_SHA_LINUX_X86_64
Linux	aarch64	shellcheck-v${PINNED}.linux.aarch64.tar.xz	$SHELLCHECK_SHA_LINUX_AARCH64
Linux	arm64	shellcheck-v${PINNED}.linux.aarch64.tar.xz	$SHELLCHECK_SHA_LINUX_AARCH64
Darwin	x86_64	shellcheck-v${PINNED}.darwin.x86_64.tar.xz	$SHELLCHECK_SHA_DARWIN_X86_64
Darwin	amd64	shellcheck-v${PINNED}.darwin.x86_64.tar.xz	$SHELLCHECK_SHA_DARWIN_X86_64
Darwin	arm64	shellcheck-v${PINNED}.darwin.aarch64.tar.xz	$SHELLCHECK_SHA_DARWIN_AARCH64
Darwin	aarch64	shellcheck-v${PINNED}.darwin.aarch64.tar.xz	$SHELLCHECK_SHA_DARWIN_AARCH64
EOF
  pass "ShellCheck installer selects the official archive, URL, and checksum per OS/arch"
}

test_installer_rejects_wrong_checksum() {
  local tmp fakebin destination out rc
  tmp=$(cs_test_tmproot cs-shellcheck-badsum)
  fakebin=$(cs_fakebin "$tmp")
  destination="$tmp/bin"

  cs_install_stub_uname "$fakebin"
  cs_install_stub_curl "$fakebin"
  cs_install_stub_hasher "$fakebin" sha256sum
  cs_install_stub_tar_shellcheck "$fakebin"
  cs_install_stub_sleep "$fakebin"

  rc=0
  out=$(SHA256_STUB_HASH=0000000000000000000000000000000000000000000000000000000000000000 \
    CS_TEST_UNAME_S=Linux CS_TEST_UNAME_M=x86_64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted a wrong checksum"$'\n'"$out"
  assert_contains "$out" "checksum mismatch" "installer did not report a checksum mismatch"
  assert_contains "$out" "shellcheck-v${PINNED}.linux.x86_64.tar.xz" \
    "mismatch did not name the selected archive"
  assert_contains "$out" "$SHELLCHECK_SHA_LINUX_X86_64" \
    "mismatch did not name the pinned linux/x86_64 checksum"
  [ ! -e "$destination/shellcheck" ] || fail "installer installed ShellCheck after a checksum mismatch"
  pass "ShellCheck installer rejects a wrong checksum"
}

test_installer_falls_back_to_shasum() {
  local tmp fakebin destination out hasher_log tool
  tmp=$(cs_test_tmproot cs-shellcheck-shasum)
  fakebin=$(cs_fakebin "$tmp")
  destination="$tmp/bin"
  hasher_log="$tmp/hasher.log"

  for tool in bash dirname mktemp rm awk mkdir install cat chmod; do
    ln -s "$(command -v "$tool")" "$fakebin/$tool"
  done
  cs_install_stub_uname "$fakebin"
  cs_install_stub_curl "$fakebin"
  cs_install_stub_hasher "$fakebin" shasum
  cs_install_stub_tar_shellcheck "$fakebin"
  cs_install_stub_sleep "$fakebin"

  : > "$hasher_log"
  out=$(CURL_URL_LOG="$tmp/curl-url.log" HASHER_LOG="$hasher_log" \
    SHA256_STUB_HASH="$SHELLCHECK_SHA_LINUX_X86_64" \
    CS_TEST_UNAME_S=Linux CS_TEST_UNAME_M=x86_64 \
    PATH="$fakebin" "$INSTALLER" "$destination" 2>&1) \
    || fail "installer did not fall back to shasum -a 256"$'\n'"$out"
  assert_grep 'shasum -a 256' "$hasher_log" "installer did not invoke shasum -a 256"
  [ -x "$destination/shellcheck" ] || fail "installer did not install ShellCheck via shasum"
  pass "ShellCheck installer falls back to shasum -a 256 when sha256sum is absent"
}

test_installer_prefers_sha256sum_over_shasum() {
  local tmp fakebin destination hasher_log
  tmp=$(cs_test_tmproot cs-shellcheck-sha256sum-pref)
  fakebin=$(cs_fakebin "$tmp")
  destination="$tmp/bin"
  hasher_log="$tmp/hasher.log"

  cs_install_stub_uname "$fakebin"
  cs_install_stub_curl "$fakebin"
  cs_install_stub_hasher "$fakebin" sha256sum
  cs_install_stub_hasher "$fakebin" shasum
  cs_install_stub_tar_shellcheck "$fakebin"
  cs_install_stub_sleep "$fakebin"

  : > "$hasher_log"
  PATH="$fakebin:$PATH" HASHER_LOG="$hasher_log" \
    SHA256_STUB_HASH="$SHELLCHECK_SHA_LINUX_X86_64" \
    CS_TEST_UNAME_S=Linux CS_TEST_UNAME_M=x86_64 \
    "$INSTALLER" "$destination" >/dev/null \
    || fail "installer failed when both hashers were present"
  assert_grep 'sha256sum' "$hasher_log" "installer did not prefer sha256sum"
  if grep -q 'shasum' "$hasher_log"; then
    fail "installer invoked shasum even though sha256sum was present"$'\n'"$(cat "$hasher_log")"
  fi
  pass "ShellCheck installer prefers sha256sum when both hashers are present"
}

test_installer_rejects_unsupported_platform() {
  local tmp fakebin destination out rc
  tmp=$(cs_test_tmproot cs-shellcheck-unsupported)
  fakebin=$(cs_fakebin "$tmp")
  destination="$tmp/bin"

  cs_install_stub_uname "$fakebin"
  cs_install_stub_curl "$fakebin"

  rc=0
  out=$(CS_TEST_UNAME_S=FreeBSD CS_TEST_UNAME_M=amd64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted an unsupported OS"$'\n'"$out"
  assert_contains "$out" "unsupported platform" "installer did not name the unsupported platform"
  assert_contains "$out" "FreeBSD-amd64" "installer did not report the detected OS/arch"

  rc=0
  out=$(CS_TEST_UNAME_S=Linux CS_TEST_UNAME_M=ppc64le \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted an unsupported architecture"$'\n'"$out"
  assert_contains "$out" "unsupported platform" "installer did not reject linux/ppc64le"
  pass "ShellCheck installer rejects an unsupported OS or architecture"
}

test_missing_shellcheck_fails_closed() {
  local tmp fakebin out rc tool
  tmp=$(cs_test_tmproot cs-lint-noshellcheck)
  fakebin=$(cs_fakebin "$tmp")
  for tool in bash dirname; do
    ln -s "$(command -v "$tool")" "$fakebin/$tool"
  done
  rc=0
  out=$(PATH="$fakebin" CI=true GITHUB_ACTIONS=true "$LINT" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "missing ShellCheck expected exit 1, got $rc"$'\n'"$out"
  assert_contains "$out" "ShellCheck not found" \
    "missing ShellCheck did not name the required linter"
  assert_contains "$out" "$PINNED" \
    "missing ShellCheck did not name the pinned version"
  assert_contains "$out" "cs-install-shellcheck.sh" \
    "missing ShellCheck did not name the pinned installer"
  pass "missing ShellCheck fails closed"
}

test_installer_retries_transient_download_failure
test_installer_selects_platform_archive_url_and_checksum
test_installer_rejects_wrong_checksum
test_installer_falls_back_to_shasum
test_installer_prefers_sha256sum_over_shasum
test_installer_rejects_unsupported_platform
test_missing_shellcheck_fails_closed
