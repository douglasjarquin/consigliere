#!/usr/bin/env bash
# Custom-check authentication for the watcher (bin/cs-watch.sh). A custom
# state/<id>.check.sh is executable ONLY from a hash-validated private
# snapshot bound by state/<id>.check-trust (written by cs-check-register.sh:
# "cs-custom-check-v1" on line one, the check's sha256 on line two, nothing
# else). Everything here is a read/validate helper: nothing in this file ever
# executes a check. Depends on the file-validation primitives in
# bin/cs-pr-lib.sh, which callers must source first.

CS_CUSTOM_CHECK_HASH=
CS_CUSTOM_CHECK_SNAPSHOT=

cs_custom_check_sha256() {
  local file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

cs_custom_check_trust_read() {
  local state=$1 id=$2 trust state_device version hash
  CS_CUSTOM_CHECK_HASH=
  cs_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(cs_pr_file_device "$state") || return 1
  trust="$state/$id.check-trust"
  cs_pr_private_file_valid "$trust" 600 "$state_device" || return 1
  exec 9< "$trust" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r hash <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _extra <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  [ "$version" = cs-custom-check-v1 ] || return 1
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  CS_CUSTOM_CHECK_HASH=$hash
}

cs_custom_check_registered() {
  local state=$1 id=$2 check hash state_device
  check="$state/$id.check.sh"
  cs_custom_check_trust_read "$state" "$id" || return 1
  state_device=$(cs_pr_file_device "$state") || return 1
  cs_pr_private_file_valid "$check" 700 "$state_device" || return 1
  hash=$(cs_custom_check_sha256 "$check") || return 1
  [ "$hash" = "$CS_CUSTOM_CHECK_HASH" ]
}

cs_custom_check_snapshot_prepare() {
  local state=$1 id=$2 check hash state_device
  cs_custom_check_snapshot_cleanup
  check="$state/$id.check.sh"
  cs_custom_check_trust_read "$state" "$id" || return 1
  state_device=$(cs_pr_file_device "$state") || return 1
  cs_pr_private_file_valid "$check" 700 "$state_device" || return 1
  CS_CUSTOM_CHECK_SNAPSHOT=$(mktemp "$state/.cs-custom-check.XXXXXX") || return 1
  cp "$check" "$CS_CUSTOM_CHECK_SNAPSHOT" || { cs_custom_check_snapshot_cleanup; return 1; }
  chmod 0600 "$CS_CUSTOM_CHECK_SNAPSHOT" || { cs_custom_check_snapshot_cleanup; return 1; }
  [ -f "$CS_CUSTOM_CHECK_SNAPSHOT" ] && [ ! -L "$CS_CUSTOM_CHECK_SNAPSHOT" ] \
    || { cs_custom_check_snapshot_cleanup; return 1; }
  [ "$(cs_pr_file_mode "$CS_CUSTOM_CHECK_SNAPSHOT")" = 600 ] \
    || { cs_custom_check_snapshot_cleanup; return 1; }
  [ "$(cs_pr_file_device "$CS_CUSTOM_CHECK_SNAPSHOT")" = "$state_device" ] \
    || { cs_custom_check_snapshot_cleanup; return 1; }
  [ "$(cs_pr_file_link_count "$CS_CUSTOM_CHECK_SNAPSHOT")" = 1 ] \
    || { cs_custom_check_snapshot_cleanup; return 1; }
  hash=$(cs_custom_check_sha256 "$CS_CUSTOM_CHECK_SNAPSHOT") \
    || { cs_custom_check_snapshot_cleanup; return 1; }
  [ "$hash" = "$CS_CUSTOM_CHECK_HASH" ] || { cs_custom_check_snapshot_cleanup; return 1; }
}

cs_custom_check_snapshot_cleanup() {
  [ -z "$CS_CUSTOM_CHECK_SNAPSHOT" ] || rm -f -- "$CS_CUSTOM_CHECK_SNAPSHOT"
  CS_CUSTOM_CHECK_SNAPSHOT=
}
