#!/usr/bin/env bash
# Behavior (portable): the Cursor Cloud Agent environment contract.
# Cloud Agents must boot the same docker/dev/Dockerfile image local compose
# and CI use, with git, passwordless sudo, no full-project COPY, and tool
# visibility that survives a PATH reset. Live Docker coverage stays in
# tests/cs-dev-tools.test.sh behind CS_TEST_DOCKER_LIVE=1.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENV_JSON="$ROOT/.cursor/environment.json"
DF="$ROOT/docker/dev/Dockerfile"
COMPOSE="$ROOT/docker-compose.yml"

assert_present "$ENV_JSON" ".cursor/environment.json must be committed"
assert_present "$DF" "docker/dev/Dockerfile must exist"

command -v python3 >/dev/null 2>&1 || fail "python3 is required to parse environment.json"
python3 - "$ENV_JSON" <<'PY' || fail "environment.json must be valid JSON"
import json, sys
json.load(open(sys.argv[1], encoding="utf-8"))
PY
pass "environment.json is valid JSON"

dockerfile=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["build"]["dockerfile"])' "$ENV_JSON")
context=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["build"]["context"])' "$ENV_JSON")
install=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["install"])' "$ENV_JSON")
user=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("user",""))' "$ENV_JSON")
has_snapshot=$(python3 -c 'import json,sys; print("yes" if "snapshot" in json.load(open(sys.argv[1], encoding="utf-8")) else "no")' "$ENV_JSON")

[ "$dockerfile" = "../docker/dev/Dockerfile" ] \
  || fail "build.dockerfile must be ../docker/dev/Dockerfile (relative to .cursor/), got $dockerfile"
[ "$context" = ".." ] \
  || fail "build.context must be .. (repo root, relative to .cursor/), got $context"
[ "$install" = "mise install" ] \
  || fail "install must be the idempotent checkout refresh 'mise install', got $install"
[ "$user" = "cs" ] \
  || fail "user must be the image runtime user cs, got $user"
[ "$has_snapshot" = "no" ] \
  || fail "environment.json must be Dockerfile-based: no snapshot field"
pass "environment.json points at docker/dev/Dockerfile with repo-root context and no snapshot"

# Paths in build.* are relative to .cursor/. Resolving them must land on the
# real files so a renamed Dockerfile cannot silently keep a stale pointer.
cursor_dir="$ROOT/.cursor"
resolved_df=$(python3 -c 'import os,sys; print(os.path.realpath(os.path.join(sys.argv[1], sys.argv[2])))' "$cursor_dir" "$dockerfile")
resolved_ctx=$(python3 -c 'import os,sys; print(os.path.realpath(os.path.join(sys.argv[1], sys.argv[2])))' "$cursor_dir" "$context")
[ "$resolved_df" = "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$DF")" ] \
  || fail "build.dockerfile must resolve to docker/dev/Dockerfile"
[ "$resolved_ctx" = "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$ROOT")" ] \
  || fail "build.context must resolve to the repo root"
pass "environment.json build paths resolve to the shared image and repo root"

assert_grep 'ARG UID=1000' "$DF" "Cloud Agents build with no DEV_UID; UID must default to 1000"
assert_grep 'ARG GID=1000' "$DF" "Cloud Agents build with no DEV_GID; GID must default to 1000"
pass "UID/GID default to 1000 for a Cloud Agent build"

grep -Eq '^[[:space:]]+git \\$' "$DF" \
  || fail "the image must install git (Cloud Agents git clone inside the container)"
grep -Eq '^[[:space:]]+sudo \\$' "$DF" \
  || fail "the image must install sudo"
assert_grep 'NOPASSWD:ALL' "$DF" "the runtime user must have passwordless sudo"
# shellcheck disable=SC2016  # literal Dockerfile text; no expansion wanted
assert_grep 'useradd -m -u "${UID}" -g "${GID}" -s /bin/bash cs' "$DF" \
  "the runtime user must stay the non-root cs account"
last_user=$(awk '/^USER / { u=$2 } END { print u }' "$DF")
[ "$last_user" = "cs" ] || fail "final USER must be cs (non-root), got $last_user"
pass "image installs git, passwordless sudo, and ends as non-root cs"

assert_no_grep 'COPY . /workspace' "$DF" "must not COPY the full project; Cursor checks out the commit"
assert_no_grep 'COPY ./ /' "$DF" "must not COPY the full project via ./ "
assert_no_grep 'ADD . ' "$DF" "must not ADD the full project"
for d in config host data state projects .no-mistakes; do
  assert_no_grep "COPY $d" "$DF" "must not COPY boss-private $d into the image"
  assert_no_grep "ADD $d" "$DF" "must not ADD boss-private $d into the image"
done
assert_grep 'COPY mise.toml /workspace/mise.toml' "$DF" \
  "mise.toml is a bake input so node/aube can be installed at image-build time"
assert_grep 'COPY bin/cs-install-shellcheck.sh /workspace/bin/cs-install-shellcheck.sh' "$DF" \
  "the ShellCheck installer is a bake input"
assert_grep 'COPY bin/cs-lint.sh /workspace/bin/cs-lint.sh' "$DF" \
  "cs-lint.sh owns the ShellCheck version pin the installer reads"
copy_sources=$(awk '/^COPY / {
  for (i = 2; i < NF; i++) print $i
}' "$DF")
while IFS= read -r src; do
  [ -n "$src" ] || continue
  case "$src" in
    mise.toml|bin/cs-install-shellcheck.sh|bin/cs-lint.sh) ;;
    *) fail "COPY source $src is not a bake input; only mise.toml and the ShellCheck installer pair are allowed" ;;
  esac
done <<EOF
$copy_sources
EOF
pass "Dockerfile copies only bake inputs, never the full project or private dirs"

assert_grep '/etc/profile.d/cs-mise.sh' "$DF" \
  "mise shims must persist via /etc/profile.d after a Cloud Agent PATH reset"
assert_grep '/home/cs/.bashrc' "$DF" \
  "mise shims must persist via the runtime user's bashrc"
# shellcheck disable=SC2016  # literal Dockerfile text; no expansion wanted
assert_grep 'ln -sfn "$shim" "/usr/local/bin/$(basename "$shim")"' "$DF" \
  "mise shims must also be linked into /usr/local/bin (stays on the default PATH)"
pass "baked tools remain visible after a Cloud Agent PATH reset"

assert_grep 'dockerfile: docker/dev/Dockerfile' "$COMPOSE" \
  "compose must keep using the same docker/dev/Dockerfile"
assert_grep 'docker compose build dev' "$ROOT/scripts/ci/run-in-container.sh" \
  "CI must keep building the same compose dev image"
pass "Mac compose and CI still consume the same image"

pass 'cs-cursor-cloud-env behaviors'
