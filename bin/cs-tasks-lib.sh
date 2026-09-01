# shellcheck shell=bash
# Shared tasks-axi backend selection, compatibility probe, and backlog
# transition helper for bootstrap, spawn, teardown, and capo backlog handoff.
# Usage: . bin/cs-tasks-lib.sh
# Compatible means tasks-axi --version reports 0.1.1 or newer,
# `tasks-axi update --help` exposes --archive-body for recoverable note rewrites,
# and `tasks-axi mv --help` exposes [<id>...] for atomic multi-ID moves required
# by capo handoffs. These probes are defense in depth behind the tasks-axi
# version floor owned by bin/cs-deps-lib.sh; they are not that floor's
# rationale, and the floor is not theirs. The 0.1.1 pin here is the oldest
# release these call paths were ever written against and is compared with the
# same shared helper, so there is one comparator in the repo, not two.
# `config/backlog-backend.conf=manual` opts out of tasks-axi for routine consigliere
# backlog mutations, but validated capo handoffs always use `tasks-axi mv`.
# Absent or any other value keeps the default tasks-axi backend path, falling
# back to manual mutation when the tool is not compatible.
# .tasks.toml at the home root owns the markdown backend schema.

CS_TASKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-deps-lib.sh
. "$CS_TASKS_LIB_DIR/cs-deps-lib.sh"

CS_TASKS_AXI_CALL_PATH_MIN=0.1.1

cs_tasks_axi_compatible() {
  cs_deps_version_at_least tasks-axi "$CS_TASKS_AXI_CALL_PATH_MIN" || return 1
  cs_tasks_axi_update_has_archive_body && cs_tasks_axi_mv_has_multi_id
}

cs_tasks_axi_update_has_archive_body() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi update --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '--archive-body' >/dev/null
}

cs_tasks_axi_mv_has_multi_id() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi mv --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '[<id>...]' >/dev/null
}

cs_backlog_backend_value() {
  local config_dir=$1 backend_file value
  backend_file="$config_dir/backlog-backend.conf"
  if [ -f "$backend_file" ]; then
    value=$(tr -d '[:space:]' < "$backend_file" 2>/dev/null || true)
    [ -n "$value" ] || value=tasks-axi
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' tasks-axi
}

cs_backlog_backend_manual() {
  local config_dir=$1
  [ "$(cs_backlog_backend_value "$config_dir")" = manual ]
}

cs_tasks_axi_backend_available() {
  local config_dir=$1
  cs_backlog_backend_manual "$config_dir" && return 1
  cs_tasks_axi_compatible
}

# cs_tasks_backlog_transition <config-dir> <verb: start|done> <item-id> [flags...]
# Folds a backlog transition into the script performing the matching physical
# change (dispatch marks In flight, teardown records done), so the two can
# never drift apart across a crash or a forgotten follow-up.
# Returns 0 when the transition landed; 2 when it was skipped because the
# configured backend is manual or no compatible tasks-axi is on PATH (a
# hand-edit reminder is printed to stderr); 1 when the write itself failed
# (tasks-axi's output is relayed to stderr). The caller decides what a
# failure means for the physical change it just made.
cs_tasks_backlog_transition() {
  local config_dir=$1 verb=$2 item=$3 backlog out
  shift 3
  backlog="$config_dir/backlog.md"
  if ! cs_tasks_axi_backend_available "$config_dir"; then
    echo "reminder: the backlog backend is manual or tasks-axi is unavailable; apply '$verb' to backlog item '$item' by hand in $backlog" >&2
    return 2
  fi
  if ! out=$(tasks-axi "$verb" "$item" --file "$backlog" "$@" 2>&1); then
    [ -n "$out" ] && printf '%s\n' "$out" >&2
    echo "error: backlog transition '$verb $item' failed against $backlog" >&2
    return 1
  fi
  return 0
}
