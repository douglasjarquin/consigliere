#!/usr/bin/env bash
# Shared validation and atomic artifact helpers for merge polling on the
# supported forges. Callers must validate task IDs and raw PR/MR URLs before
# constructing task paths or performing any side effect. Sourced by the
# watcher (bin/cs-watch.sh) to authenticate a byte-static PR merge poll before
# execution, and by cs-pr-check.sh to publish one.
#
# The stored identity is provider-tagged: provider, url, host, path, number.
# "path" is the full project path, which is owner/repository on GitHub and an
# arbitrarily nested group/subgroup/project namespace on GitLab. A GitLab
# project can sit at any depth, so no owner/repository pair can address one and
# the sidecar carries the whole path instead. GitLab also runs on self-hosted
# instances, so the host is part of that identity rather than a constant. Every
# consumer re-derives the identity from the stored URL and refuses any record
# whose parts do not reconstruct that exact URL.

CS_PR_PROVIDER=
CS_PR_URL=
CS_PR_HOST=
CS_PR_PATH=
CS_PR_OWNER=
CS_PR_REPO=
CS_PR_NUMBER=
CS_PR_DATA_PROVIDER=
CS_PR_DATA_URL=
CS_PR_DATA_HOST=
CS_PR_DATA_PATH=
CS_PR_DATA_NUMBER=
CS_PR_META_PROVIDER=
CS_PR_META_URL=
CS_PR_META_HOST=
CS_PR_META_PATH=
CS_PR_META_NUMBER=
CS_PR_REG_ID=
CS_PR_REG_PROVIDER=
CS_PR_REG_URL=
CS_PR_REG_HOST=
CS_PR_REG_PATH=
CS_PR_REG_NUMBER=
CS_PR_REG_DATA_HASH=
CS_PR_REG_TEMPLATE_HASH=
CS_PR_REG_DATA_IDENTITY=
CS_PR_REG_CHECK_IDENTITY=
CS_PR_POLL_DATA_TMP=
CS_PR_POLL_CHECK_TMP=
CS_PR_POLL_REG_TMP=
CS_PR_POLL_DATA_DEST=
CS_PR_POLL_CHECK_DEST=
CS_PR_POLL_REG_DEST=
CS_PR_POLL_EXPECT_ID=
CS_PR_POLL_EXPECT_PROVIDER=
CS_PR_POLL_EXPECT_URL=
CS_PR_POLL_EXPECT_HOST=
CS_PR_POLL_EXPECT_PATH=
CS_PR_POLL_EXPECT_NUMBER=
CS_PR_POLL_EXPECT_DATA_HASH=
CS_PR_POLL_EXPECT_TEMPLATE_HASH=
CS_PR_POLL_EXPECT_DATA_IDENTITY=
CS_PR_POLL_EXPECT_CHECK_IDENTITY=
CS_PR_POLL_TEMPLATE=
CS_PR_POLL_STATE_DEVICE=

cs_task_id_path_safe() {
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

cs_pr_task_id_valid() {
  local id=${1-}
  cs_task_id_path_safe "$id"
}

cs_task_id_creation_valid() {
  local id=${1-}
  cs_pr_task_id_valid "$id" || return 1
  [ "${#id}" -le 64 ]
}

# GitLab serves self-hosted instances, so the host is part of the identity
# rather than a constant. It is accepted only as a lowercase DNS name with no
# userinfo, port, or trailing dot, which keeps one canonical spelling per MR.
# github.com is refused here even though its shape is otherwise valid: it is
# GitHub's own host and never a GitLab instance, so a URL like
# https://github.com/o/r/-/merge_requests/1 (a typo'd or spoofed GitHub URL)
# would otherwise be armed as a GitLab watch that can never succeed.
cs_pr_gitlab_host_valid() {
  local host=${1-} label
  local LC_ALL=C
  local -a labels
  [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || return 1
  [ "$host" != github.com ] || return 1
  case "$host" in
    .*|*.|*..*|*[!a-z0-9.-]*) return 1 ;;
  esac
  IFS=. read -ra labels <<< "$host"
  for label in "${labels[@]}"; do
    [ "${#label}" -ge 1 ] && [ "${#label}" -le 63 ] || return 1
    case "$label" in
      -*|*-) return 1 ;;
    esac
  done
}

# A GitLab project path is group[/subgroup...]/project, so at least two
# segments and no fixed depth. GitLab reserves "-" as its route separator and
# forbids a leading hyphen, ".git", and ".atom", so none of those can name a
# real namespace and each is refused here.
cs_pr_gitlab_path_valid() {
  local path=${1-} segment
  local LC_ALL=C
  local -a segments
  [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || return 1
  case "$path" in
    /*|*/|*//*) return 1 ;;
  esac
  IFS=/ read -ra segments <<< "$path"
  [ "${#segments[@]}" -ge 2 ] && [ "${#segments[@]}" -le 20 ] || return 1
  for segment in "${segments[@]}"; do
    [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || return 1
    case "$segment" in
      .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
  done
}

# Parse a canonical PR or MR URL into the provider-tagged identity. Validation
# is strict and per provider: the GitHub username and repository rules are
# unchanged, and GitLab gets its own host and namespace rules rather than a
# loosened GitHub rule.
#
# CS_PR_OWNER and CS_PR_REPO are additionally set for github because the merge
# path addresses GitHub by owner/repository. A gitlab URL leaves them empty.
cs_pr_url_parse() {
  local raw=${1-} pattern host path
  local LC_ALL=C
  CS_PR_PROVIDER=
  CS_PR_URL=
  CS_PR_HOST=
  CS_PR_PATH=
  CS_PR_OWNER=
  CS_PR_REPO=
  CS_PR_NUMBER=
  pattern='^https://github\.com/([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])/([A-Za-z0-9._-]{1,100})/pull/([1-9][0-9]*)$'
  if [[ "$raw" =~ $pattern ]]; then
    [[ "${BASH_REMATCH[1]}" != *--* ]] || return 1
    [ "${BASH_REMATCH[2]}" != . ] && [ "${BASH_REMATCH[2]}" != .. ] || return 1
    CS_PR_PROVIDER=github
    CS_PR_URL=$raw
    CS_PR_HOST=github.com
    CS_PR_PATH="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    # Consumed by the merge path, which addresses GitHub by owner/repository.
    # shellcheck disable=SC2034
    CS_PR_OWNER=${BASH_REMATCH[1]}
    # shellcheck disable=SC2034
    CS_PR_REPO=${BASH_REMATCH[2]}
    CS_PR_NUMBER=${BASH_REMATCH[3]}
    return 0
  fi
  # The path class contains "/" and "-", so this match is greedy to the last
  # "/-/merge_requests/". Any earlier separator therefore lands inside the
  # captured path, where the reserved "-" segment is refused.
  pattern='^https://([a-z0-9.-]{1,253})/([A-Za-z0-9._/-]+)/-/merge_requests/([1-9][0-9]*)$'
  [[ "$raw" =~ $pattern ]] || return 1
  host=${BASH_REMATCH[1]}
  path=${BASH_REMATCH[2]}
  cs_pr_gitlab_host_valid "$host" || return 1
  cs_pr_gitlab_path_valid "$path" || return 1
  CS_PR_PROVIDER=gitlab
  CS_PR_URL=$raw
  CS_PR_HOST=$host
  CS_PR_PATH=$path
  CS_PR_NUMBER=${BASH_REMATCH[3]}
}

cs_pr_head_valid() {
  local head=${1-}
  local LC_ALL=C
  [[ "$head" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]]
}

cs_pr_file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

cs_pr_file_device() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %d "$1" 2>/dev/null
  else
    stat -c %d "$1" 2>/dev/null
  fi
}

cs_pr_file_link_count() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

cs_pr_file_inode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %i "$1" 2>/dev/null
  else
    stat -c %i "$1" 2>/dev/null
  fi
}

cs_pr_file_identity() {
  local device inode
  device=$(cs_pr_file_device "$1") || return 1
  inode=$(cs_pr_file_inode "$1") || return 1
  [ -n "$device" ] && [ -n "$inode" ] || return 1
  printf '%s:%s\n' "$device" "$inode"
}

cs_pr_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

cs_pr_private_file_valid() {
  local path=$1 mode=$2 device=$3
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(cs_pr_file_mode "$path")" = "$mode" ] || return 1
  [ "$(cs_pr_file_device "$path")" = "$device" ] || return 1
  [ "$(cs_pr_file_link_count "$path")" = 1 ]
}

cs_pr_regular_destination_or_absent() {
  local path=$1
  [ ! -L "$path" ] || return 1
  if [ -e "$path" ]; then
    [ -f "$path" ] && [ "$(cs_pr_file_link_count "$path")" = 1 ]
  fi
}

cs_pr_regular_destination_on_device_or_absent() {
  local path=$1 device=$2
  cs_pr_regular_destination_or_absent "$path" || return 1
  [ ! -e "$path" ] || [ "$(cs_pr_file_device "$path")" = "$device" ]
}

cs_pr_metadata_identity_parse() {
  local file=$1 line value pr_count=0 seen_pr=0 post_pr_invalid=0
  CS_PR_META_PROVIDER=
  CS_PR_META_URL=
  CS_PR_META_HOST=
  CS_PR_META_PATH=
  CS_PR_META_NUMBER=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(cs_pr_file_link_count "$file")" = 1 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      pr=*)
        pr_count=$((pr_count + 1))
        [ "$pr_count" -eq 1 ] || continue
        value=${line#pr=}
        if cs_pr_url_parse "$value"; then
          CS_PR_META_PROVIDER=$CS_PR_PROVIDER
          CS_PR_META_URL=$CS_PR_URL
          CS_PR_META_HOST=$CS_PR_HOST
          CS_PR_META_PATH=$CS_PR_PATH
          CS_PR_META_NUMBER=$CS_PR_NUMBER
        fi
        seen_pr=1
        ;;
      pr_head=*)
        if [ "$seen_pr" -eq 1 ]; then
          value=${line#pr_head=}
          cs_pr_head_valid "$value" || post_pr_invalid=1
        fi
        ;;
      *)
        [ "$seen_pr" -eq 0 ] || post_pr_invalid=1
        ;;
    esac
  done < "$file"
  [ "$pr_count" -eq 1 ] || return 1
  [ "$post_pr_invalid" -eq 0 ] || return 1
  [ -n "$CS_PR_META_URL" ]
}

# Sidecar layout: provider, url, host, path, number, one per line. A sidecar
# with any other shape fails the field count or the identity re-derivation and
# is refused rather than misread.
cs_pr_poll_data_parse() {
  local file=$1 provider url host path number
  CS_PR_DATA_PROVIDER=
  CS_PR_DATA_URL=
  CS_PR_DATA_HOST=
  CS_PR_DATA_PATH=
  CS_PR_DATA_NUMBER=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 8< "$file" || return 1
  IFS= read -r provider <&8 || { exec 8<&-; return 1; }
  IFS= read -r url <&8 || { exec 8<&-; return 1; }
  IFS= read -r host <&8 || { exec 8<&-; return 1; }
  IFS= read -r path <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  cs_pr_url_parse "$url" || return 1
  [ "$provider" = "$CS_PR_PROVIDER" ] || return 1
  [ "$host" = "$CS_PR_HOST" ] || return 1
  [ "$path" = "$CS_PR_PATH" ] || return 1
  [ "$number" = "$CS_PR_NUMBER" ] || return 1
  CS_PR_DATA_PROVIDER=$CS_PR_PROVIDER
  CS_PR_DATA_URL=$CS_PR_URL
  CS_PR_DATA_HOST=$CS_PR_HOST
  CS_PR_DATA_PATH=$CS_PR_PATH
  CS_PR_DATA_NUMBER=$CS_PR_NUMBER
}

# Registration layout: version tag, task id, then the same provider-tagged
# identity as the sidecar, then the two hashes and the two file identities.
# A registration carrying any other version tag is refused.
cs_pr_poll_registration_parse() {
  local file=$1 version id provider url host path number data_hash template_hash data_identity check_identity
  CS_PR_REG_ID=
  CS_PR_REG_PROVIDER=
  CS_PR_REG_URL=
  CS_PR_REG_HOST=
  CS_PR_REG_PATH=
  CS_PR_REG_NUMBER=
  CS_PR_REG_DATA_HASH=
  CS_PR_REG_TEMPLATE_HASH=
  CS_PR_REG_DATA_IDENTITY=
  CS_PR_REG_CHECK_IDENTITY=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 7< "$file" || return 1
  IFS= read -r version <&7 || { exec 7<&-; return 1; }
  IFS= read -r id <&7 || { exec 7<&-; return 1; }
  IFS= read -r provider <&7 || { exec 7<&-; return 1; }
  IFS= read -r url <&7 || { exec 7<&-; return 1; }
  IFS= read -r host <&7 || { exec 7<&-; return 1; }
  IFS= read -r path <&7 || { exec 7<&-; return 1; }
  IFS= read -r number <&7 || { exec 7<&-; return 1; }
  IFS= read -r data_hash <&7 || { exec 7<&-; return 1; }
  IFS= read -r template_hash <&7 || { exec 7<&-; return 1; }
  IFS= read -r data_identity <&7 || { exec 7<&-; return 1; }
  IFS= read -r check_identity <&7 || { exec 7<&-; return 1; }
  if IFS= read -r _extra <&7; then
    exec 7<&-
    return 1
  fi
  exec 7<&-
  [ "$version" = cs-pr-poll-registration-v2 ] || return 1
  cs_pr_task_id_valid "$id" || return 1
  cs_pr_url_parse "$url" || return 1
  [ "$provider" = "$CS_PR_PROVIDER" ] || return 1
  [ "$host" = "$CS_PR_HOST" ] || return 1
  [ "$path" = "$CS_PR_PATH" ] || return 1
  [ "$number" = "$CS_PR_NUMBER" ] || return 1
  [[ "$data_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$template_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$data_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [[ "$check_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  CS_PR_REG_ID=$id
  CS_PR_REG_PROVIDER=$CS_PR_PROVIDER
  CS_PR_REG_URL=$CS_PR_URL
  CS_PR_REG_HOST=$CS_PR_HOST
  CS_PR_REG_PATH=$CS_PR_PATH
  CS_PR_REG_NUMBER=$CS_PR_NUMBER
  CS_PR_REG_DATA_HASH=$data_hash
  CS_PR_REG_TEMPLATE_HASH=$template_hash
  CS_PR_REG_DATA_IDENTITY=$data_identity
  CS_PR_REG_CHECK_IDENTITY=$check_identity
}

cs_pr_poll_cleanup() {
  [ -z "$CS_PR_POLL_DATA_TMP" ] || rm -f -- "$CS_PR_POLL_DATA_TMP"
  [ -z "$CS_PR_POLL_CHECK_TMP" ] || rm -f -- "$CS_PR_POLL_CHECK_TMP"
  [ -z "$CS_PR_POLL_REG_TMP" ] || rm -f -- "$CS_PR_POLL_REG_TMP"
  CS_PR_POLL_DATA_TMP=
  CS_PR_POLL_CHECK_TMP=
  CS_PR_POLL_REG_TMP=
}

cs_pr_poll_revoke_final() {
  local failed=0
  # Neutralize the runnable name first so a failed rearm cannot consume state
  # whose transactional registration did not commit successfully.
  if [ -e "$CS_PR_POLL_CHECK_DEST" ] || [ -L "$CS_PR_POLL_CHECK_DEST" ]; then
    rm -f -- "$CS_PR_POLL_CHECK_DEST" || failed=1
  fi
  if [ -e "$CS_PR_POLL_REG_DEST" ] || [ -L "$CS_PR_POLL_REG_DEST" ]; then
    rm -f -- "$CS_PR_POLL_REG_DEST" || failed=1
  fi
  if [ -e "$CS_PR_POLL_DATA_DEST" ] || [ -L "$CS_PR_POLL_DATA_DEST" ]; then
    rm -f -- "$CS_PR_POLL_DATA_DEST" || failed=1
  fi
  [ ! -e "$CS_PR_POLL_CHECK_DEST" ] && [ ! -L "$CS_PR_POLL_CHECK_DEST" ] || failed=1
  [ ! -e "$CS_PR_POLL_REG_DEST" ] && [ ! -L "$CS_PR_POLL_REG_DEST" ] || failed=1
  [ ! -e "$CS_PR_POLL_DATA_DEST" ] && [ ! -L "$CS_PR_POLL_DATA_DEST" ] || failed=1
  return "$failed"
}

cs_pr_poll_prepare() {
  local state=$1 id=$2 provider=$3 url=$4 host=$5 path=$6 number=$7 template=$8
  cs_pr_task_id_valid "$id" || return 1
  cs_pr_url_parse "$url" || return 1
  [ "$provider" = "$CS_PR_PROVIDER" ] || return 1
  [ "$host" = "$CS_PR_HOST" ] || return 1
  [ "$path" = "$CS_PR_PATH" ] || return 1
  [ "$number" = "$CS_PR_NUMBER" ] || return 1
  [ -f "$template" ] || return 1

  [ ! -L "$state" ] || return 1
  mkdir -p "$state" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  umask 077
  CS_PR_POLL_DATA_DEST="$state/$id.pr-poll"
  CS_PR_POLL_CHECK_DEST="$state/$id.check.sh"
  CS_PR_POLL_REG_DEST="$state/$id.pr-poll-registration"
  CS_PR_POLL_EXPECT_ID=$id
  CS_PR_POLL_EXPECT_PROVIDER=$provider
  CS_PR_POLL_EXPECT_URL=$url
  CS_PR_POLL_EXPECT_HOST=$host
  CS_PR_POLL_EXPECT_PATH=$path
  CS_PR_POLL_EXPECT_NUMBER=$number
  CS_PR_POLL_TEMPLATE=$template
  CS_PR_POLL_STATE_DEVICE=$(cs_pr_file_device "$state") || return 1
  [ -n "$CS_PR_POLL_STATE_DEVICE" ] || return 1
  CS_PR_POLL_DATA_TMP=$(mktemp "$state/.cs-pr-poll-data.XXXXXX") || return 1
  CS_PR_POLL_CHECK_TMP=$(mktemp "$state/.cs-pr-poll-check.XXXXXX") || {
    cs_pr_poll_cleanup
    return 1
  }
  CS_PR_POLL_REG_TMP=$(mktemp "$state/.cs-pr-poll-registration.XXXXXX") || {
    cs_pr_poll_cleanup
    return 1
  }

  if ! printf '%s\n%s\n%s\n%s\n%s\n' "$provider" "$url" "$host" "$path" "$number" > "$CS_PR_POLL_DATA_TMP" \
    || ! chmod 0600 "$CS_PR_POLL_DATA_TMP" \
    || ! cs_pr_private_file_valid "$CS_PR_POLL_DATA_TMP" 600 "$CS_PR_POLL_STATE_DEVICE" \
    || ! cs_pr_poll_data_parse "$CS_PR_POLL_DATA_TMP" \
    || [ "$CS_PR_DATA_PROVIDER" != "$provider" ] \
    || [ "$CS_PR_DATA_URL" != "$url" ] \
    || [ "$CS_PR_DATA_HOST" != "$host" ] \
    || [ "$CS_PR_DATA_PATH" != "$path" ] \
    || [ "$CS_PR_DATA_NUMBER" != "$number" ] \
    || ! cp "$template" "$CS_PR_POLL_CHECK_TMP" \
    || ! chmod 0600 "$CS_PR_POLL_CHECK_TMP" \
    || ! cs_pr_private_file_valid "$CS_PR_POLL_CHECK_TMP" 600 "$CS_PR_POLL_STATE_DEVICE" \
    || ! cmp -s "$template" "$CS_PR_POLL_CHECK_TMP"; then
    cs_pr_poll_cleanup
    return 1
  fi
  CS_PR_POLL_EXPECT_DATA_HASH=$(cs_pr_sha256 "$CS_PR_POLL_DATA_TMP") || { cs_pr_poll_cleanup; return 1; }
  CS_PR_POLL_EXPECT_TEMPLATE_HASH=$(cs_pr_sha256 "$CS_PR_POLL_CHECK_TMP") || { cs_pr_poll_cleanup; return 1; }
  CS_PR_POLL_EXPECT_DATA_IDENTITY=$(cs_pr_file_identity "$CS_PR_POLL_DATA_TMP") || { cs_pr_poll_cleanup; return 1; }
  CS_PR_POLL_EXPECT_CHECK_IDENTITY=$(cs_pr_file_identity "$CS_PR_POLL_CHECK_TMP") || { cs_pr_poll_cleanup; return 1; }
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      cs-pr-poll-registration-v2 "$id" "$provider" "$url" "$host" "$path" "$number" \
      "$CS_PR_POLL_EXPECT_DATA_HASH" "$CS_PR_POLL_EXPECT_TEMPLATE_HASH" \
      "$CS_PR_POLL_EXPECT_DATA_IDENTITY" "$CS_PR_POLL_EXPECT_CHECK_IDENTITY" \
      > "$CS_PR_POLL_REG_TMP" \
    || ! chmod 0600 "$CS_PR_POLL_REG_TMP" \
    || ! cs_pr_private_file_valid "$CS_PR_POLL_REG_TMP" 600 "$CS_PR_POLL_STATE_DEVICE" \
    || ! cs_pr_poll_registration_parse "$CS_PR_POLL_REG_TMP" \
    || [ "$CS_PR_REG_ID" != "$id" ] \
    || [ "$CS_PR_REG_DATA_HASH" != "$CS_PR_POLL_EXPECT_DATA_HASH" ] \
    || [ "$CS_PR_REG_TEMPLATE_HASH" != "$CS_PR_POLL_EXPECT_TEMPLATE_HASH" ]; then
    cs_pr_poll_cleanup
    return 1
  fi
}

cs_pr_poll_publish_prepared() {
  [ -n "$CS_PR_POLL_DATA_TMP" ] && [ -n "$CS_PR_POLL_CHECK_TMP" ] \
    && [ -n "$CS_PR_POLL_REG_TMP" ] || return 1
  cs_pr_regular_destination_on_device_or_absent "$CS_PR_POLL_DATA_DEST" "$CS_PR_POLL_STATE_DEVICE" || return 1
  cs_pr_regular_destination_on_device_or_absent "$CS_PR_POLL_REG_DEST" "$CS_PR_POLL_STATE_DEVICE" || return 1
  cs_pr_regular_destination_on_device_or_absent "$CS_PR_POLL_CHECK_DEST" "$CS_PR_POLL_STATE_DEVICE" || return 1

  if ! mv -f -- "$CS_PR_POLL_DATA_TMP" "$CS_PR_POLL_DATA_DEST"; then
    cs_pr_poll_revoke_final || true
    return 1
  fi
  CS_PR_POLL_DATA_TMP=
  if ! cs_pr_private_file_valid "$CS_PR_POLL_DATA_DEST" 600 "$CS_PR_POLL_STATE_DEVICE" \
    || [ "$(cs_pr_file_identity "$CS_PR_POLL_DATA_DEST")" != "$CS_PR_POLL_EXPECT_DATA_IDENTITY" ] \
    || [ "$(cs_pr_sha256 "$CS_PR_POLL_DATA_DEST")" != "$CS_PR_POLL_EXPECT_DATA_HASH" ] \
    || ! cs_pr_poll_data_parse "$CS_PR_POLL_DATA_DEST" \
    || [ "$CS_PR_DATA_PROVIDER" != "$CS_PR_POLL_EXPECT_PROVIDER" ] \
    || [ "$CS_PR_DATA_URL" != "$CS_PR_POLL_EXPECT_URL" ] \
    || [ "$CS_PR_DATA_HOST" != "$CS_PR_POLL_EXPECT_HOST" ] \
    || [ "$CS_PR_DATA_PATH" != "$CS_PR_POLL_EXPECT_PATH" ] \
    || [ "$CS_PR_DATA_NUMBER" != "$CS_PR_POLL_EXPECT_NUMBER" ]; then
    cs_pr_poll_revoke_final || true
    return 1
  fi

  if ! mv -f -- "$CS_PR_POLL_REG_TMP" "$CS_PR_POLL_REG_DEST"; then
    cs_pr_poll_revoke_final || true
    return 1
  fi
  CS_PR_POLL_REG_TMP=
  if ! cs_pr_private_file_valid "$CS_PR_POLL_REG_DEST" 600 "$CS_PR_POLL_STATE_DEVICE" \
    || ! cs_pr_poll_registration_parse "$CS_PR_POLL_REG_DEST" \
    || [ "$CS_PR_REG_ID" != "$CS_PR_POLL_EXPECT_ID" ] \
    || [ "$CS_PR_REG_PROVIDER" != "$CS_PR_POLL_EXPECT_PROVIDER" ] \
    || [ "$CS_PR_REG_URL" != "$CS_PR_POLL_EXPECT_URL" ] \
    || [ "$CS_PR_REG_HOST" != "$CS_PR_POLL_EXPECT_HOST" ] \
    || [ "$CS_PR_REG_PATH" != "$CS_PR_POLL_EXPECT_PATH" ] \
    || [ "$CS_PR_REG_NUMBER" != "$CS_PR_POLL_EXPECT_NUMBER" ] \
    || [ "$CS_PR_REG_DATA_HASH" != "$CS_PR_POLL_EXPECT_DATA_HASH" ] \
    || [ "$CS_PR_REG_TEMPLATE_HASH" != "$CS_PR_POLL_EXPECT_TEMPLATE_HASH" ] \
    || [ "$CS_PR_REG_DATA_IDENTITY" != "$CS_PR_POLL_EXPECT_DATA_IDENTITY" ] \
    || [ "$CS_PR_REG_CHECK_IDENTITY" != "$CS_PR_POLL_EXPECT_CHECK_IDENTITY" ]; then
    cs_pr_poll_revoke_final || true
    return 1
  fi

  if ! cs_pr_regular_destination_on_device_or_absent "$CS_PR_POLL_CHECK_DEST" "$CS_PR_POLL_STATE_DEVICE" \
    || ! mv -f -- "$CS_PR_POLL_CHECK_TMP" "$CS_PR_POLL_CHECK_DEST"; then
    cs_pr_poll_revoke_final || true
    return 1
  fi
  CS_PR_POLL_CHECK_TMP=
  if ! cs_pr_poll_artifacts_valid "${CS_PR_POLL_CHECK_DEST%/*}" "$CS_PR_POLL_EXPECT_ID" "$CS_PR_POLL_TEMPLATE"; then
    cs_pr_poll_revoke_final || true
    return 1
  fi
}

cs_pr_poll_artifacts_valid() {
  local state=$1 id=$2 template=$3 state_device check data registration meta data_hash template_hash data_identity check_identity
  cs_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(cs_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"
  data="$state/$id.pr-poll"
  registration="$state/$id.pr-poll-registration"
  meta="$state/$id.meta"
  cs_pr_private_file_valid "$check" 600 "$state_device" || return 1
  cs_pr_private_file_valid "$data" 600 "$state_device" || return 1
  cs_pr_private_file_valid "$registration" 600 "$state_device" || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(cs_pr_file_link_count "$meta")" = 1 ] || return 1
  cmp -s "$template" "$check" || return 1
  cs_pr_poll_data_parse "$data" || return 1
  data_hash=$(cs_pr_sha256 "$data") || return 1
  template_hash=$(cs_pr_sha256 "$check") || return 1
  data_identity=$(cs_pr_file_identity "$data") || return 1
  check_identity=$(cs_pr_file_identity "$check") || return 1
  cs_pr_poll_registration_parse "$registration" || return 1
  [ "$CS_PR_REG_ID" = "$id" ] || return 1
  [ "$CS_PR_REG_PROVIDER" = "$CS_PR_DATA_PROVIDER" ] || return 1
  [ "$CS_PR_REG_URL" = "$CS_PR_DATA_URL" ] || return 1
  [ "$CS_PR_REG_HOST" = "$CS_PR_DATA_HOST" ] || return 1
  [ "$CS_PR_REG_PATH" = "$CS_PR_DATA_PATH" ] || return 1
  [ "$CS_PR_REG_NUMBER" = "$CS_PR_DATA_NUMBER" ] || return 1
  [ "$CS_PR_REG_DATA_HASH" = "$data_hash" ] || return 1
  [ "$CS_PR_REG_TEMPLATE_HASH" = "$template_hash" ] || return 1
  [ "$CS_PR_REG_DATA_IDENTITY" = "$data_identity" ] || return 1
  [ "$CS_PR_REG_CHECK_IDENTITY" = "$check_identity" ] || return 1
  cs_pr_metadata_identity_parse "$meta" || return 1
  [ "$CS_PR_META_PROVIDER" = "$CS_PR_DATA_PROVIDER" ] || return 1
  [ "$CS_PR_META_URL" = "$CS_PR_DATA_URL" ] || return 1
  [ "$CS_PR_META_HOST" = "$CS_PR_DATA_HOST" ] || return 1
  [ "$CS_PR_META_PATH" = "$CS_PR_DATA_PATH" ] || return 1
  [ "$CS_PR_META_NUMBER" = "$CS_PR_DATA_NUMBER" ]
}
