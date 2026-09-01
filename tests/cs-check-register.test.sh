#!/usr/bin/env bash
# tests/cs-check-register.test.sh - bin/cs-check-register.sh: binding a
# boss-written custom state/<id>.check.sh (ordinary single-link mode-0700
# file) to its current bytes via a private state/<id>.check-trust record, the
# only thing that lets bin/cs-watch.sh execute it. Validated against the REAL
# trust-read/snapshot helpers in bin/cs-check-lib.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/cs-pr-lib.sh
. "$ROOT/bin/cs-pr-lib.sh"
# shellcheck source=bin/cs-check-lib.sh
. "$ROOT/bin/cs-check-lib.sh"

REGISTER="$ROOT/bin/cs-check-register.sh"
TMP_ROOT=$(cs_test_tmproot cs-check-register)

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

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

test_registers_and_authenticates_with_real_lib() {
  local dir state out hash
  dir=$(make_case register-ok); state="$dir/state"
  write_check "$state" custom
  out=$(CS_STATE_OVERRIDE="$state" "$REGISTER" custom) \
    || fail "registration of a private single-link 0700 check failed"
  [ "$out" = 'registered: state/custom.check.sh' ] || fail "registration confirmation line was not exact: $out"
  [ -f "$state/custom.check-trust" ] || fail "no trust record was written"
  [ "$(file_mode "$state/custom.check-trust")" = 600 ] || fail "trust record mode was not 0600"
  hash=$(shasum -a 256 "$state/custom.check.sh" | awk '{print $1}')
  [ "$(cat "$state/custom.check-trust")" = "$(printf 'cs-custom-check-v1\n%s' "$hash")" ] \
    || fail "trust record bytes were not the versioned hash binding"
  # The REAL watcher-side validation must accept the registration.
  cs_custom_check_registered "$state" custom \
    || fail "real cs_custom_check_registered rejected a fresh registration"
  cs_custom_check_snapshot_prepare "$state" custom \
    || fail "real watcher snapshot preparation rejected a fresh registration"
  cs_custom_check_snapshot_cleanup
  # Re-registration after an intentional edit rebinds to the new bytes.
  printf 'echo "second line"\n' >> "$state/custom.check.sh"
  ! cs_custom_check_registered "$state" custom \
    || fail "edited check remained authenticated under the old binding"
  CS_STATE_OVERRIDE="$state" "$REGISTER" custom >/dev/null \
    || fail "re-registration after an intentional edit failed"
  cs_custom_check_registered "$state" custom \
    || fail "re-registration did not rebind the edited bytes"
  pass "registration binds current bytes, the real check-lib authenticates it, and re-registration rebinds"
}

test_invalid_or_missing_inputs_refused() {
  local dir state rc id
  dir=$(make_case register-refusals); state="$dir/state"

  # shellcheck disable=SC2016 # Literal shell syntax is task-ID test data.
  for id in '../escape' 'a/b' '.' '..' '.task' 'task a' 'task$a' 'task;a'; do
    set +e
    CS_STATE_OVERRIDE="$state" "$REGISTER" "$id" > /dev/null 2> "$dir/stderr"
    rc=$?
    set -e
    expect_code 2 "$rc" "invalid task ID '$id' was not refused"
    assert_grep 'error: invalid custom check registration' "$dir/stderr" \
      "invalid task ID refusal was not fixed"
  done
  [ ! -e "$TMP_ROOT/escape.check-trust" ] || fail "task traversal wrote a trust record outside state"

  set +e
  CS_STATE_OVERRIDE="$state" "$REGISTER" > /dev/null 2>&1; rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "zero-argument registration was accepted"

  set +e
  CS_STATE_OVERRIDE="$state" "$REGISTER" absent > /dev/null 2> "$dir/stderr"; rc=$?
  set -e
  expect_code 1 "$rc" "registration without a check file was not refused"
  assert_grep 'error: custom check is unavailable' "$dir/stderr" \
    "missing-check refusal was not explained"
  [ ! -e "$state/absent.check-trust" ] || fail "a trust record was written for a missing check"
  pass "invalid task IDs and missing checks are refused before any trust record exists"
}

test_non_private_or_multilink_source_refused() {
  local dir state rc alias
  dir=$(make_case register-non-private); state="$dir/state"

  # Wrong mode: 0755 is not the required private 0700.
  write_check "$state" custom
  chmod 0755 "$state/custom.check.sh"
  set +e
  CS_STATE_OVERRIDE="$state" "$REGISTER" custom > /dev/null 2> "$dir/stderr"; rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "registration accepted a non-private (0755) source"
  [ ! -e "$state/custom.check-trust" ] || fail "non-private custom check received a trust record"

  # Hard-linked source: a second name means the bytes can change under the hash.
  chmod 0700 "$state/custom.check.sh"
  alias="$dir/custom-check.alias"
  ln "$state/custom.check.sh" "$alias"
  set +e
  CS_STATE_OVERRIDE="$state" "$REGISTER" custom > /dev/null 2> "$dir/stderr"; rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "registration accepted a hard-linked source"
  [ ! -e "$state/custom.check-trust" ] || fail "hard-linked custom check received a trust record"
  rm -f "$alias"

  # Symlinked source is never a registrable check.
  printf '#!/usr/bin/env bash\necho x\n' > "$dir/outside.sh"
  chmod 0700 "$dir/outside.sh"
  ln -s "$dir/outside.sh" "$state/linked.check.sh"
  set +e
  CS_STATE_OVERRIDE="$state" "$REGISTER" linked > /dev/null 2> "$dir/stderr"; rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "registration accepted a symlinked source"
  [ ! -e "$state/linked.check-trust" ] || fail "symlinked custom check received a trust record"
  pass "non-private, hard-linked, and symlinked check sources are refused without a trust record"
}

test_post_registration_tamper_deauthenticates() {
  local dir state alias
  dir=$(make_case register-tamper); state="$dir/state"
  write_check "$state" custom
  CS_STATE_OVERRIDE="$state" "$REGISTER" custom >/dev/null \
    || fail "could not register the tamper fixture"

  # Byte tamper after registration: the real lib must reject execution.
  printf 'echo "tampered"\n' >> "$state/custom.check.sh"
  ! cs_custom_check_registered "$state" custom \
    || fail "tampered check remained authenticated"
  ! cs_custom_check_snapshot_prepare "$state" custom \
    || fail "watcher snapshot accepted a tampered check"
  cs_custom_check_snapshot_cleanup

  # Hard-linking the source or the trust record after registration also
  # deauthenticates (single-link is part of the private-file contract).
  dir=$(make_case register-tamper-links); state="$dir/state"
  write_check "$state" custom
  CS_STATE_OVERRIDE="$state" "$REGISTER" custom >/dev/null \
    || fail "could not register the link-tamper fixture"
  alias="$dir/source.alias"
  ln "$state/custom.check.sh" "$alias"
  ! cs_custom_check_registered "$state" custom \
    || fail "registered check remained authenticated after source hard-linking"
  rm -f "$alias"
  alias="$dir/trust.alias"
  ln "$state/custom.check-trust" "$alias"
  ! cs_custom_check_registered "$state" custom \
    || fail "hard-linked trust record remained authenticated"
  ! cs_custom_check_snapshot_prepare "$state" custom \
    || fail "watcher snapshot accepted a hard-linked trust record"
  cs_custom_check_snapshot_cleanup
  [ -e "$alias" ] || fail "trust hard-link refusal removed the external alias"
  pass "post-registration tampering (bytes or extra links) deauthenticates the check for the real watcher lib"
}

test_registers_and_authenticates_with_real_lib
test_invalid_or_missing_inputs_refused
test_non_private_or_multilink_source_refused
test_post_registration_tamper_deauthenticates
