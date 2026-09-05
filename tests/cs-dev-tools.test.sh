#!/usr/bin/env bash
# Behavior (LIVE, opt-in): the dev-tools suite's container pieces build and run
# correctly - the dev/web images build, the seven boss-private paths stay masked
# inside the dev container, the tracked tree is still visible there, the web
# service serves the built docs site, and bin/cs-test-run.sh --portable passes
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

cleanup() {
  "${COMPOSE[@]}" down >/dev/null 2>&1 || true
  cs_test_cleanup
}
trap cleanup EXIT

"${COMPOSE[@]}" build dev web >/dev/null || fail "dev/web images build"
pass "dev and web images build"

sensitive_ok=1
for d in config host data state projects .no-mistakes .made/evidence; do
  count=$("${COMPOSE[@]}" run --rm dev sh -c "ls /workspace/$d 2>/dev/null | wc -l" | tr -d ' ')
  [ "$count" = 0 ] || { sensitive_ok=0; echo "LEAK: $d has $count entries" >&2; }
done
[ "$sensitive_ok" = 1 ] || fail "boss-private paths must stay masked inside the dev container"
pass "config/host/data/state/projects/.no-mistakes/.made/evidence stay masked inside dev"

tracked_lines=$("${COMPOSE[@]}" run --rm dev sh -c 'wc -l < /workspace/bin/cs-test-run.sh' | tr -d ' ')
[ "$tracked_lines" -gt 0 ] 2>/dev/null || fail "the tracked tree must still be visible inside dev"
pass "the tracked tree is visible inside dev"

features_file=$("${COMPOSE[@]}" run --rm dev sh -c 'test -f /workspace/.made/features/README.md && echo visible')
[ "$features_file" = visible ] || fail "the tracked Made feature index must stay visible inside dev"
pass "the tracked Made feature index is visible inside dev"

mise run web:install >/dev/null || fail "docs site install"
mise run web:build >/dev/null || fail "docs site build"
"${COMPOSE[@]}" up -d web >/dev/null || fail "web service starts"
sleep 2
web_body=$(curl -fsS http://localhost:8080/ 2>&1) || fail "web service must respond on :8080"
assert_contains "$web_body" "You describe the work" \
  "web service must serve the built docs site"
pass "web service serves the docs site"

container_out=$("${COMPOSE[@]}" run --rm dev bin/cs-test-run.sh --portable 2>&1)
container_rc=$?
[ "$container_rc" -eq 0 ] || fail "containerized portable run must pass: $container_out"
pass "bin/cs-test-run.sh --portable passes inside the dev container"

pass 'cs-dev-tools behaviors'
