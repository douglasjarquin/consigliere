#!/usr/bin/env bash
# tests/lib.sh - shared primitives for consigliere behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Provides ok/not-ok reporters, a self-cleaning temp root, fakebin/PATH-shim
# helpers, deterministic git identity and fixture builders, state/<id>.meta
# writers, and the common string/exit-code/file assertions. It deliberately
# does NOT bundle behavior-specific fake herdr/codex/no-mistakes mocks: those
# encode terminal and lifecycle assumptions that differ per suite and belong
# with the tests that own them.
#
# ROOT is exported as the consigliere repo root (this file lives in tests/).

# Idempotent guard: helper files may source this library for ROOT/fail/pass,
# and the test that includes them may also source it directly. Re-sourcing
# must not wipe the registered-cleanup array or reset state.
if [ -n "${CS_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
CS_TEST_LIB_SOURCED=1

# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# --- self-cleaning temp root ------------------------------------------------
#
# cs_test_tmproot <prefix> echoes a fresh temp dir and registers it for removal
# on EXIT. The first call installs the cleanup trap. A test file that needs
# extra teardown (e.g. killing a daemon) should define its own EXIT trap and
# call cs_test_cleanup from inside it so registered dirs are still removed.

CS_TEST_CLEANUP_DIRS=()

cs_test_cleanup() {
  local d
  for d in "${CS_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}

cs_test_tmproot() {
  local prefix=${1:-cs-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")
  if [ "${#CS_TEST_CLEANUP_DIRS[@]}" -eq 0 ]; then
    trap cs_test_cleanup EXIT
  fi
  CS_TEST_CLEANUP_DIRS+=("$root")
  printf '%s\n' "$root"
}

# --- fakebin / PATH shims ---------------------------------------------------
#
# cs_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. cs_fake_exit0 drops trivial exit-0 stubs for
# the named tools into a fakebin dir.

cs_fakebin() {
  local fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

cs_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# --- deterministic git identity and fixtures --------------------------------

cs_git_identity() {
  export GIT_AUTHOR_NAME=${1:-cstest} GIT_AUTHOR_EMAIL=${2:-cstest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

cs_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Consigliere Tests' -c user.email='tests@example.invalid' commit -qm initial
}

cs_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

cs_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  cs_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

cs_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# --- common assertions ------------------------------------------------------

assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

assert_present() {
  [ -e "$1" ] || fail "$2"
}
