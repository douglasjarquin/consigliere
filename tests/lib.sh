#!/usr/bin/env bash
# tests/lib.sh - shared primitives for consigliere behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Provides ok/not-ok reporters, a self-cleaning temp root, fakebin/PATH-shim
# helpers, deterministic git identity and fixture builders, state/<id>.meta
# writers, the common string/line/exit-code/file assertions, and the version
# fixture derivation floor-gated suites share. It deliberately
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

# Pin the harness for tests so behavior does not depend on the developer's own
# session (a codex dev has no CLAUDECODE; a claude dev's session would otherwise
# leak CLAUDECODE=1 into cs_harness_detect_root). Defaults to codex, matching the
# existing fixtures; a claude-specific test sets CS_HARNESS_OVERRIDE=claude before
# sourcing this file.
: "${CS_HARNESS_OVERRIDE:=codex}"
export CS_HARNESS_OVERRIDE

# Pin the OPTIONAL turn telemetry off for every suite. Most tests override only
# CS_STATE_OVERRIDE, so their DATA still resolves to the real repo checkout: on a
# machine whose home has telemetry enabled, an uninstrumented suite would append
# synthetic test turns to the developer's own measurement dataset. The telemetry
# suites unset this deliberately for the cases that need it on.
: "${CS_TELEMETRY_DISABLE:=1}"
export CS_TELEMETRY_DISABLE

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cs_git_disable_commit_signing() {
  local index=${GIT_CONFIG_COUNT:-0}
  case "$index" in
    ''|*[!0-9]*) fail "GIT_CONFIG_COUNT must be a non-negative integer" ;;
  esac
  export "GIT_CONFIG_KEY_$index=commit.gpgsign"
  export "GIT_CONFIG_VALUE_$index=false"
  export GIT_CONFIG_COUNT=$((index + 1))
}

cs_git_disable_commit_signing

# --- self-cleaning temp root ------------------------------------------------
#
# cs_test_tmproot <prefix> echoes a fresh temp dir and registers it for removal
# on EXIT. A test file that needs extra teardown (e.g. killing a daemon) should
# define its own EXIT trap and call cs_test_cleanup from inside it, so registered
# dirs are still removed after its own teardown has run.
#
# WHY A FILE AND NOT AN ARRAY. The registry used to be a shell array that
# cs_test_tmproot appended to, with the EXIT trap installed by its first call.
# Both were dead code. Every caller uses the function as
# `TMP_ROOT=$(cs_test_tmproot foo)`, so its body runs in a command-substitution
# SUBSHELL: neither the append nor the `trap` ever reached the caller, and every
# suite leaked its whole fixture tree on every run. A file survives the subshell,
# and `$$` stays the invoking shell's pid inside one (BASHPID is what changes), so
# parent and subshell agree on the registry path with nothing passed between them.
CS_TEST_TMPBASE="${TMPDIR:-/tmp}"
CS_TEST_TMPBASE="${CS_TEST_TMPBASE%/}"
CS_TEST_REGISTRY="$CS_TEST_TMPBASE/cs-test-reg.$$"
# Start from an empty registry: pids recycle, so a registry file left by a dead
# run must not be inherited as if this suite had created those dirs.
: > "$CS_TEST_REGISTRY"

# The trap is installed HERE, at source time, in the caller's own shell - never
# from inside cs_test_tmproot, where the subshell would swallow it. The suites
# that install their own EXIT trap override this one and call cs_test_cleanup from
# their handler, which is what keeps that override correct.
trap cs_test_cleanup EXIT

# Safe to call more than once: a suite's own handler may call it and then EXIT
# fires again. The registry is consumed, so the second pass finds nothing.
cs_test_cleanup() {
  local d leaf
  [ -f "$CS_TEST_REGISTRY" ] || return 0
  while IFS= read -r d; do
    # Only ever remove what this library can actually have minted: an IMMEDIATE
    # child of the temp base. mktemp -d always produces exactly that, so anything
    # deeper, anything outside the base, the bare base itself, and any traversal
    # are all refusals - a corrupted or hand-edited registry must not turn into an
    # rm -rf somewhere else.
    case "$d" in
      "$CS_TEST_TMPBASE"/?*) leaf=${d#"$CS_TEST_TMPBASE"/} ;;
      *) continue ;;
    esac
    case "$leaf" in
      */*|.|..) continue ;;
    esac
    rm -rf "$d"
  done < "$CS_TEST_REGISTRY"
  rm -f "$CS_TEST_REGISTRY"
}

cs_test_tmproot() {
  local prefix=${1:-cs-test} root
  root=$(mktemp -d "$CS_TEST_TMPBASE/${prefix}.XXXXXX")
  printf '%s\n' "$root" >> "$CS_TEST_REGISTRY"
  printf '%s\n' "$root"
}

# --- fakebin / PATH shims ---------------------------------------------------
#
# cs_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. cs_fake_exit0 drops trivial exit-0 stubs for
# the named tools into a fakebin dir. cs_fake_version_tool drops a stub for a
# tool whose installed version bootstrap gates, so a fixture is not reported as
# an unparseable (below-floor) build simply for answering --version with
# nothing.

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

# cs_fake_version_tool <fakebin> <tool> <override-env-var> <default-version>
# The stub answers --version with <override-env-var> when that variable is set
# and non-empty, and with <default-version> otherwise; every other invocation
# exits 0. A case that needs to drive a version floor exports the variable.
# 9.9.9 is the conventional default: above any real floor, so a suite that
# merely runs bootstrap is never reported as an out-of-date build.
cs_fake_version_tool() {
  local fakebin=$1 tool=$2 override=$3 default=$4
  cat > "$fakebin/$tool" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' "\${$override:-$default}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
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

# assert_line <output> <extended-regex> <label> - the anchored form of
# assert_contains: one LINE of <output> must match (or, for assert_no_line, must
# not match) the regex, so a suite can pin a report column layout or an
# output-line prefix rather than a substring found anywhere.
assert_line() {
  printf '%s\n' "$1" | grep -Eq -- "$2" ||
    fail "$3 (no line matching /$2/)"$'\n'"--- output ---"$'\n'"$1"
}

assert_no_line() {
  printf '%s\n' "$1" | grep -Eq -- "$2" &&
    fail "$3 (unexpected line matching /$2/)"$'\n'"--- output ---"$'\n'"$1"
  return 0
}

# cs_test_version_below <version> - the highest dotted version that still orders
# below <version>, for suites that derive a below-floor fixture from a floor the
# implementation owns instead of hardcoding a number that drifts on the next
# bump. A zero field has nothing to decrement, so the borrow moves to the
# next-higher field and the fields below it saturate: 0.2.0 -> 0.1.9999. An
# all-zero version has nothing below it and exits nonzero, which callers must
# turn into a loud failure rather than an empty fixture.
cs_test_version_below() {
  printf '%s\n' "$1" | awk -F. -v OFS=. '{
    i = NF
    while (i > 1 && $i == 0) i--
    if ($i == 0) exit 1
    $i = $i - 1
    for (j = i + 1; j <= NF; j++) $j = 9999
    print
  }'
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
