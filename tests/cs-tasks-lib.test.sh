#!/usr/bin/env bash
# Behavior tests for bin/cs-tasks-lib.sh: the tasks-axi availability/compat
# probe, the manual-backend predicate, and config/backlog-backend.conf reading.
# Fully offline: every tasks-axi is a fakebin shim; the real tool (if any) is
# excluded from PATH for the no-tool case.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(cs_test_tmproot cs-tasks-lib)
LIB="$ROOT/bin/cs-tasks-lib.sh"

# write_fake_tasks_axi <fakebin> <version> <update-help-body> <mv-help-body>
write_fake_tasks_axi() {
  local fakebin=$1 version=$2 update_help=$3 mv_help=$4
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' '$version'
  exit 0
fi
if [ "\${1:-}" = update ] && [ "\${2:-}" = --help ]; then
  printf '%s\n' '$update_help'
  exit 0
fi
if [ "\${1:-}" = mv ] && [ "\${2:-}" = --help ]; then
  printf '%s\n' '$mv_help'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
}

UPDATE_OK='usage: tasks-axi update <id> --archive-body'
UPDATE_BARE='usage: tasks-axi update <id>'
MV_OK='usage: tasks-axi mv <id> [<id>...] --to <path>'
MV_BARE='usage: tasks-axi mv <id> --to <path>'

# run_probe <fakebin-or-empty> <function> [args...]: source the lib in a clean
# shell whose PATH holds only the fakebin plus system dirs, so the real
# tasks-axi (if installed) never leaks into the probe.
run_probe() {
  local fakebin=$1 fn=$2 path
  shift 2
  path="/usr/bin:/bin"
  [ -n "$fakebin" ] && path="$fakebin:$path"
  # shellcheck disable=SC2016 # $1/$fn expand inside the child bash, by design.
  env PATH="$path" bash -c '. "$1"; fn=$2; shift 2; "$fn" "$@"' _ "$LIB" "$fn" "$@"
}

test_compat_probe() {
  local d fb rc

  d="$TMP_ROOT/compat-011"; fb=$(cs_fakebin "$d")
  write_fake_tasks_axi "$fb" "0.1.1" "$UPDATE_OK" "$MV_OK"
  run_probe "$fb" cs_tasks_axi_compatible \
    || fail "0.1.1 with --archive-body and multi-id mv must be compatible"

  d="$TMP_ROOT/compat-022"; fb=$(cs_fakebin "$d")
  write_fake_tasks_axi "$fb" "0.2.2" "$UPDATE_OK" "$MV_OK"
  run_probe "$fb" cs_tasks_axi_compatible \
    || fail "0.2.2 with both capabilities must be compatible"

  d="$TMP_ROOT/compat-010"; fb=$(cs_fakebin "$d")
  write_fake_tasks_axi "$fb" "0.1.0" "$UPDATE_OK" "$MV_OK"
  set +e; run_probe "$fb" cs_tasks_axi_compatible; rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "0.1.0 must be incompatible (below 0.1.1)"

  d="$TMP_ROOT/compat-noarchive"; fb=$(cs_fakebin "$d")
  write_fake_tasks_axi "$fb" "0.2.2" "$UPDATE_BARE" "$MV_OK"
  set +e; run_probe "$fb" cs_tasks_axi_compatible; rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "missing --archive-body must be incompatible"

  d="$TMP_ROOT/compat-nomulti"; fb=$(cs_fakebin "$d")
  write_fake_tasks_axi "$fb" "0.2.2" "$UPDATE_OK" "$MV_BARE"
  set +e; run_probe "$fb" cs_tasks_axi_compatible; rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "missing multi-id mv must be incompatible"

  set +e; run_probe "" cs_tasks_axi_compatible; rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "absent tasks-axi must be incompatible"

  pass "compat probe requires >=0.1.1, --archive-body, and multi-id mv"
}

# The probe reads the version through the shared comparator, so it accepts the
# same shapes the session-start floor does: one release, bare or behind a single
# tool-name prefix. Prose that merely contains a dotted token is not a version
# statement and must not read as compatible.
test_version_acceptance() {
  local d fb rc
  d="$TMP_ROOT/version-plain"; fb=$(cs_fakebin "$d")
  write_fake_tasks_axi "$fb" "1.12.3" "$UPDATE_OK" "$MV_OK"
  run_probe "$fb" cs_tasks_axi_compatible || fail "1.12.3 must be compatible"

  d="$TMP_ROOT/version-prefixed"; fb=$(cs_fakebin "$d")
  write_fake_tasks_axi "$fb" "tasks-axi 1.12.3" "$UPDATE_OK" "$MV_OK"
  run_probe "$fb" cs_tasks_axi_compatible \
    || fail "a version behind its own tool name must be compatible"

  d="$TMP_ROOT/version-decorated"; fb=$(cs_fakebin "$d")
  write_fake_tasks_axi "$fb" "tasks-axi version 1.12.3 (release)" "$UPDATE_OK" "$MV_OK"
  set +e; run_probe "$fb" cs_tasks_axi_compatible; rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "text around the version must not read as comparable"

  pass "compatibility reads one release, bare or behind a tool-name prefix"
}

test_backlog_backend_value() {
  local config="$TMP_ROOT/config-value"
  mkdir -p "$config"

  [ "$(run_probe "" cs_backlog_backend_value "$config")" = tasks-axi ] \
    || fail "absent config/backlog-backend.conf must default to tasks-axi"

  printf 'manual\n' > "$config/backlog-backend.conf"
  [ "$(run_probe "" cs_backlog_backend_value "$config")" = manual ] \
    || fail "manual value must be read back"

  printf '  manual \n' > "$config/backlog-backend.conf"
  [ "$(run_probe "" cs_backlog_backend_value "$config")" = manual ] \
    || fail "surrounding whitespace must be stripped"

  printf '\n' > "$config/backlog-backend.conf"
  [ "$(run_probe "" cs_backlog_backend_value "$config")" = tasks-axi ] \
    || fail "blank file must fall back to tasks-axi"

  printf 'something-else\n' > "$config/backlog-backend.conf"
  [ "$(run_probe "" cs_backlog_backend_value "$config")" = something-else ] \
    || fail "unknown values pass through for the caller to default"

  pass "config/backlog-backend.conf reading defaults, trims, and passes through"
}

test_manual_predicate_and_availability() {
  local d fb config rc
  d="$TMP_ROOT/availability"; fb=$(cs_fakebin "$d")
  write_fake_tasks_axi "$fb" "0.2.2" "$UPDATE_OK" "$MV_OK"
  config="$d/config"
  mkdir -p "$config"

  set +e; run_probe "$fb" cs_backlog_backend_manual "$config"; rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "absent config must not read as manual"
  run_probe "$fb" cs_tasks_axi_backend_available "$config" \
    || fail "default backend with compatible tasks-axi must be available"

  printf 'manual\n' > "$config/backlog-backend.conf"
  run_probe "$fb" cs_backlog_backend_manual "$config" \
    || fail "manual config must satisfy the manual predicate"
  set +e; run_probe "$fb" cs_tasks_axi_backend_available "$config"; rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "manual opt-out must disable the tasks-axi backend even when compatible"

  printf 'tasks-axi\n' > "$config/backlog-backend.conf"
  run_probe "$fb" cs_tasks_axi_backend_available "$config" \
    || fail "explicit tasks-axi config with compatible tool must be available"

  write_fake_tasks_axi "$fb" "0.1.0" "$UPDATE_OK" "$MV_OK"
  set +e; run_probe "$fb" cs_tasks_axi_backend_available "$config"; rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "incompatible tasks-axi must not report the backend available"

  pass "manual predicate and backend availability compose compat and config"
}

test_compat_probe
test_version_acceptance
test_backlog_backend_value
test_manual_predicate_and_availability
