#!/usr/bin/env bash
# tests/cs-check-unregister.test.sh - bin/cs-check-unregister.sh: the safe
# owner of custom-check retirement. It validates the id and the state
# directory (refusing an explicitly EMPTY CS_STATE_OVERRIDE) before removing
# state/<id>.check.sh, its trust binding, and its watcher sidecars, and
# refuses any artifact that is not an ordinary single-link file on the state
# directory's device.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REGISTER="$ROOT/bin/cs-check-register.sh"
UNREGISTER="$ROOT/bin/cs-check-unregister.sh"
TMP_ROOT=$(cs_test_tmproot cs-check-unregister)

make_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  printf '%s\n' "$dir"
}

write_check() {
  local state=$1 id=$2
  cat > "$state/$id.check.sh" <<'SH'
#!/usr/bin/env bash
echo "custom-ready"
SH
  chmod 0700 "$state/$id.check.sh"
}

test_unregisters_check_trust_and_sidecars() {
  local dir state out
  dir=$(make_case unregister-ok); state="$dir/state"
  write_check "$state" custom
  CS_STATE_OVERRIDE="$state" "$REGISTER" custom >/dev/null \
    || fail "could not register the retirement fixture"
  : > "$state/custom.pr-poll"
  : > "$state/custom.pr-poll-registration"
  : > "$state/custom.board-seen"
  : > "$state/other.check-trust"
  out=$(CS_STATE_OVERRIDE="$state" "$UNREGISTER" custom) \
    || fail "unregistration of a registered check failed"
  [ "$out" = 'unregistered: state/custom.check.sh' ] \
    || fail "unregistration confirmation line was not exact: $out"
  [ ! -e "$state/custom.check.sh" ] || fail "the check script survived retirement"
  [ ! -e "$state/custom.check-trust" ] || fail "the trust binding survived retirement"
  [ ! -e "$state/custom.pr-poll" ] || fail "the pr-poll sidecar survived retirement"
  [ ! -e "$state/custom.pr-poll-registration" ] || fail "the pr-poll registration survived retirement"
  [ ! -e "$state/custom.board-seen" ] || fail "the board-seen sidecar survived retirement"
  [ -e "$state/other.check-trust" ] || fail "another task's trust binding was removed"
  CS_STATE_OVERRIDE="$state" "$UNREGISTER" custom >/dev/null \
    || fail "unregistering an already-retired check must succeed (idempotent)"
  pass "unregistration removes exactly the check, its trust binding, and its sidecars"
}

test_invalid_id_and_arity_refused() {
  local dir state rc id
  dir=$(make_case unregister-refusals); state="$dir/state"
  write_check "$state" custom

  # shellcheck disable=SC2016 # Literal shell syntax is task-ID test data.
  for id in '../escape' 'a/b' '.' '..' '.task' 'task a' 'task$a' 'task;a'; do
    set +e
    CS_STATE_OVERRIDE="$state" "$UNREGISTER" "$id" > /dev/null 2> "$dir/stderr"
    rc=$?
    set -e
    expect_code 2 "$rc" "invalid task ID '$id' was not refused"
    assert_grep 'error: invalid custom check unregistration' "$dir/stderr" \
      "invalid task ID refusal was not explained"
  done

  set +e
  CS_STATE_OVERRIDE="$state" "$UNREGISTER" > /dev/null 2>&1; rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "zero-argument unregistration was accepted"
  [ -e "$state/custom.check.sh" ] || fail "a refused unregistration removed the check"
  pass "invalid task IDs and missing arguments are refused before any removal"
}

test_empty_or_bad_state_refused() {
  local dir state rc
  dir=$(make_case unregister-state); state="$dir/state"
  write_check "$state" custom

  # An explicitly EMPTY override is a caller bug, never the default.
  set +e
  CS_STATE_OVERRIDE="" "$UNREGISTER" custom > /dev/null 2> "$dir/stderr"; rc=$?
  set -e
  expect_code 1 "$rc" "an explicitly empty CS_STATE_OVERRIDE was not refused"
  assert_grep 'set but empty' "$dir/stderr" \
    "the empty-override refusal was not explained"
  [ -e "$state/custom.check.sh" ] || fail "the empty-override refusal removed the check"

  set +e
  CS_STATE_OVERRIDE="$dir/absent-state" "$UNREGISTER" custom > /dev/null 2> "$dir/stderr"; rc=$?
  set -e
  expect_code 1 "$rc" "a missing state directory was not refused"
  assert_grep 'error: state directory is unavailable' "$dir/stderr" \
    "the missing-state refusal was not explained"

  ln -s "$state" "$dir/link-state"
  set +e
  CS_STATE_OVERRIDE="$dir/link-state" "$UNREGISTER" custom > /dev/null 2> "$dir/stderr"; rc=$?
  set -e
  expect_code 1 "$rc" "a symlinked state directory was not refused"
  pass "empty, missing, and symlinked state directories are refused before any removal"
}

test_unsafe_artifacts_refused() {
  local dir state rc alias
  dir=$(make_case unregister-unsafe); state="$dir/state"

  printf '#!/usr/bin/env bash\necho x\n' > "$dir/outside.sh"
  chmod 0700 "$dir/outside.sh"
  ln -s "$dir/outside.sh" "$state/linked.check.sh"
  set +e
  CS_STATE_OVERRIDE="$state" "$UNREGISTER" linked > /dev/null 2> "$dir/stderr"; rc=$?
  set -e
  expect_code 1 "$rc" "a symlinked check artifact was not refused"
  assert_grep 'error: custom check is unsafe to remove' "$dir/stderr" \
    "the unsafe-artifact refusal was not explained"
  [ -e "$dir/outside.sh" ] || fail "the refusal removed the symlink target"
  [ -L "$state/linked.check.sh" ] || fail "the refusal removed the symlinked artifact"

  write_check "$state" custom
  alias="$dir/custom-check.alias"
  ln "$state/custom.check.sh" "$alias"
  set +e
  CS_STATE_OVERRIDE="$state" "$UNREGISTER" custom > /dev/null 2> "$dir/stderr"; rc=$?
  set -e
  expect_code 1 "$rc" "a hard-linked check artifact was not refused"
  [ -e "$state/custom.check.sh" ] || fail "the hard-link refusal removed the check"
  rm -f "$alias"
  pass "symlinked and multi-link artifacts are refused without removing anything"
}

test_unregisters_check_trust_and_sidecars
test_invalid_id_and_arity_refused
test_empty_or_bad_state_refused
test_unsafe_artifacts_refused
