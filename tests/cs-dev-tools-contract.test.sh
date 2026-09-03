#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENVIRONMENT="$ROOT/.cursor/environment.json"
DOCKERFILE="$ROOT/docker/dev/Dockerfile"
DOCKERIGNORE="$ROOT/.dockerignore"
COMPOSE="$ROOT/docker-compose.yml"

if ! environment_out=$(python3 - "$ENVIRONMENT" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if not path.is_file():
    print(f"missing {path}", file=sys.stderr)
    raise SystemExit(1)

try:
    config = json.loads(path.read_text())
except json.JSONDecodeError as error:
    print(f"invalid JSON: {error}", file=sys.stderr)
    raise SystemExit(1)

build = config.get("build")
if not isinstance(build, dict):
    print("build must be an object", file=sys.stderr)
    raise SystemExit(1)
if build.get("dockerfile") != "../docker/dev/Dockerfile":
    print("build.dockerfile must be ../docker/dev/Dockerfile", file=sys.stderr)
    raise SystemExit(1)
if build.get("context") != "..":
    print("build.context must be ..", file=sys.stderr)
    raise SystemExit(1)
if "snapshot" in config:
    print("snapshot must be absent", file=sys.stderr)
    raise SystemExit(1)
if config.get("install") != "mise install":
    print("install must be the idempotent project-root refresh: mise install", file=sys.stderr)
    raise SystemExit(1)
print("environment.json: Dockerfile build, repository-root context, no snapshot, idempotent install")
PY
); then
  printf '%s\n' "$environment_out" >&2
  fail "Cursor Cloud environment contract"
fi
printf '%s\n' "$environment_out"
pass "Cursor Cloud environment.json contract"

if ! dockerfile_out=$(python3 - "$DOCKERFILE" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text()
required = {
    "git": re.search(r"^\s+git\s+\\$", source, re.MULTILINE),
    "sudo": re.search(r"^\s+sudo\s+\\$", source, re.MULTILINE),
    "passwordless sudo": "NOPASSWD:ALL" in source,
    "default UID": "ARG UID=1000" in source,
    "default GID": "ARG GID=1000" in source,
    "system mise data": "MISE_DATA_DIR=/usr/local/share/mise" in source,
    "system mise config": "MISE_CONFIG_DIR=/usr/local/etc/mise" in source,
    "mise manifest": "COPY mise.toml" in source,
    "ShellCheck installer": "COPY bin/cs-install-shellcheck.sh" in source,
    "ShellCheck pin reader": "COPY bin/cs-lint.sh" in source,
}
missing = [name for name, present in required.items() if not present]
if missing:
    print("missing Dockerfile requirements: " + ", ".join(missing), file=sys.stderr)
    raise SystemExit(1)
if re.search(r"^\s*COPY\s+(?:--[^ ]+\s+)*\.\s+", source, re.MULTILINE):
    print("Dockerfile must not COPY the full project", file=sys.stderr)
    raise SystemExit(1)
if not re.search(r"/usr/local/share/mise/shims.*(?:bashrc|/usr/local/bin)|(?:bashrc|/usr/local/bin).* /usr/local/share/mise/shims", source, re.IGNORECASE):
    print("mise tools need PATH persistence beyond ENV PATH", file=sys.stderr)
    raise SystemExit(1)
print("Dockerfile: git, sudo, passwordless sudo, UID/GID defaults, narrow tool copies, no full-project COPY, persistent tool visibility")
PY
); then
  printf '%s\n' "$dockerfile_out" >&2
  fail "Cursor Cloud Dockerfile contract"
fi
printf '%s\n' "$dockerfile_out"
pass "Cursor Cloud Dockerfile contract"

for path in config host data state projects .no-mistakes; do
  assert_grep "$path" "$DOCKERIGNORE" ".dockerignore excludes $path from image context"
  assert_grep "/workspace/$path" "$COMPOSE" "Compose masks $path inside dev"
done
pass "private operational paths stay excluded from image and Compose view"

pass "cs-dev-tools portable contract"
