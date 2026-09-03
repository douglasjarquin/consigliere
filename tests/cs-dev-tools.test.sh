#!/usr/bin/env bash
# Behavior (LIVE, opt-in): the dev-tools suite's container pieces build and run
# correctly - the dev/web images build, the six boss-private paths stay masked
# inside the dev container, the tracked tree is still visible there, the web
# service serves the placeholder, and bin/cs-test-run.sh --portable passes
# inside the dev container.
#
# Skipped unless CS_TEST_DOCKER_LIVE=1 because it provisions real containers.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${CS_TEST_DOCKER_LIVE:-0}" != "1" ]; then
  pass "cs-dev-tools suite skipped (set CS_TEST_DOCKER_LIVE=1 to run)"
  exit 0
fi

export DEV_UID="${DEV_UID:-$(id -u)}"
export DEV_GID="${DEV_GID:-$(id -g)}"
COMPOSE=(docker compose -f "$ROOT/docker-compose.yml")
UID1000_IMAGE=cs-dev-uid1000-test

cleanup() {
  "${COMPOSE[@]}" down >/dev/null 2>&1 || true
  docker rmi "$UID1000_IMAGE" >/dev/null 2>&1 || true
  cs_test_cleanup
}
trap cleanup EXIT

"${COMPOSE[@]}" build dev web >/dev/null || fail "dev/web images build"
pass "dev and web images build"

sensitive_ok=1
for d in config host data state projects .no-mistakes; do
  count=$("${COMPOSE[@]}" run --rm dev sh -c "ls /workspace/$d 2>/dev/null | wc -l" | tr -d ' ')
  [ "$count" = 0 ] || { sensitive_ok=0; echo "LEAK: $d has $count entries" >&2; }
done
[ "$sensitive_ok" = 1 ] || fail "boss-private paths must stay masked inside the dev container"
pass "config/host/data/state/projects/.no-mistakes stay masked inside dev"

tracked_lines=$("${COMPOSE[@]}" run --rm dev sh -c 'wc -l < /workspace/bin/cs-test-run.sh' | tr -d ' ')
[ "$tracked_lines" -gt 0 ] 2>/dev/null || fail "the tracked tree must still be visible inside dev"
pass "the tracked tree is visible inside dev"

"${COMPOSE[@]}" up -d web >/dev/null || fail "web service starts"
sleep 2
web_body=$(curl -fsS http://localhost:8080/ 2>&1) || fail "web service must respond on :8080"
assert_contains "$web_body" "consigliere dev environment placeholder" \
  "web service must serve the fixed placeholder body"
pass "web service serves the placeholder"

container_out=$("${COMPOSE[@]}" run --rm dev bin/cs-test-run.sh --portable 2>&1)
container_rc=$?
[ "$container_rc" -eq 0 ] || fail "containerized portable run must pass: $container_out"
pass "bin/cs-test-run.sh --portable passes inside the dev container"

# Cursor Cloud Agents build this image with no DEV_UID/DEV_GID, so the
# Dockerfile defaults (1000:1000) are the Cloud Agent path. Local compose
# above used this machine's uid and does not cover that.
docker build --build-arg UID=1000 --build-arg GID=1000 \
  -t "$UID1000_IMAGE" -f "$ROOT/docker/dev/Dockerfile" "$ROOT" >/dev/null \
  || fail "default UID/GID 1000 image must build"
pass "default UID/GID 1000 image builds"

# Override PATH to the distro default (no mise shims dir, no image ENV PATH)
# so this matches a Cloud Agent PATH reset. bash -c does not source bashrc.
uid1000_out=$(docker run --rm --user cs \
  -e PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  "$UID1000_IMAGE" \
  bash -c 'id -un; command -v git; command -v sudo; command -v mise; command -v node; command -v tasks-axi; sudo -n true' 2>&1) \
  || fail "UID 1000 image must keep git/sudo/mise/node/tasks-axi on a reset PATH with passwordless sudo: $uid1000_out"
assert_contains "$uid1000_out" "cs" "UID 1000 image must run as cs"
assert_contains "$uid1000_out" "/usr/bin/git" "git must remain on the reset PATH"
assert_contains "$uid1000_out" "/usr/bin/sudo" "sudo must remain on the reset PATH"
assert_contains "$uid1000_out" "mise" "mise must remain on the reset PATH"
assert_contains "$uid1000_out" "node" "node must remain on the reset PATH after a Cloud Agent PATH reset"
assert_contains "$uid1000_out" "tasks-axi" "tasks-axi must remain on the reset PATH after a Cloud Agent PATH reset"
pass "UID 1000 image keeps tools on a reset PATH with passwordless sudo"

pass 'cs-dev-tools behaviors'
