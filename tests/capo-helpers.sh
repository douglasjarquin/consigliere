#!/usr/bin/env bash
# tests/capo-helpers.sh - shared fixtures and mocks for the capo suites
# (cs-home-seed, cs-inherit, cs-send-capo, cs-pending-reply, and
# cs-backlog-handoff behavior tests).
#
# These mocks encode capo-lifecycle behavior (a fixture "consigliere repo" for
# detached-worktree homes, a fake herdr that answers the pane/agent calls the
# capo paths make), so they live here rather than in the generic tests/lib.sh.
# The generic git/identity/meta primitives come from lib.sh, which this file
# pulls in.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# cs_capo_fixture_repo <dir> - a minimal "consigliere repo" fixture: AGENTS.md,
# bin/, and the operational-dir .gitignore the real repo carries, committed on
# main. Used as CS_ROOT_OVERRIDE so seeded capo homes are worktrees of a
# throwaway repo, never the real checkout.
cs_capo_fixture_repo() {
  local dir=$1
  mkdir -p "$dir/bin"
  printf '# fixture consigliere\n' > "$dir/AGENTS.md"
  printf 'tool\n' > "$dir/bin/tool.sh"
  printf 'data/\nstate/\nconfig/\nprojects/\n.env\n.no-mistakes/\n' > "$dir/.gitignore"
  git -C "$dir" init -q -b main
  git -C "$dir" add -A
  git -C "$dir" -c user.name='Consigliere Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# cs_capo_fixture_project <sandbox> <home> <name> - a project clone with a
# file:// origin under <home>/projects/<name>, plus its bare remote at
# <sandbox>/<name>-remote.git. Register it in config/projects.md yourself.
cs_capo_fixture_project() {
  local sandbox=$1 home=$2 name=$3
  git init -q "$sandbox/src-$name"
  printf '%s\n' "$name" > "$sandbox/src-$name/README.md"
  git -C "$sandbox/src-$name" add -A
  git -C "$sandbox/src-$name" -c user.name='Consigliere Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone -q --bare "$sandbox/src-$name" "$sandbox/$name-remote.git"
  mkdir -p "$home/projects"
  git clone -q "$sandbox/$name-remote.git" "$home/projects/$name"
}

# cs_capo_registry_line <id> <summary> <home> <scope> [projects] [added] - one
# canonical config/host/capos.md row, exactly as bin/cs-home-seed.sh writes it.
cs_capo_registry_line() {
  printf -- '- %s - %s (home: %s; scope: %s; projects: %s; added %s)\n' \
    "$1" "$2" "$3" "$4" "${5:-}" "${6:-2026-01-01}"
}

# cs_capo_registry_write <file> [--no-final-newline] <line>... - write a capo
# routing table fixture, each <line> verbatim on its own line.
# --no-final-newline leaves the LAST line unterminated. That is not an exotic
# shape: any hand edit can produce it, and it is what used to make every
# `while read` consumer silently drop the last registered capo.
cs_capo_registry_write() {
  local file=$1 final_newline=1 line i=0 total
  shift
  if [ "${1:-}" = --no-final-newline ]; then
    final_newline=0
    shift
  fi
  total=$#
  mkdir -p "$(dirname "$file")"
  : > "$file"
  for line in "$@"; do
    i=$((i + 1))
    if [ "$i" -eq "$total" ] && [ "$final_newline" -eq 0 ]; then
      printf '%s' "$line" >> "$file"
    else
      printf '%s\n' "$line" >> "$file"
    fi
  done
}

# cs_capo_fake_herdr <fakebin> - a fake herdr for capo send/liveness paths.
# Behavior knobs (env):
#   FAKE_PANE_EXISTS  0 makes `pane get` fail (pane gone); default 1
#   FAKE_AGENT        non-empty = agent name reported by `agent get`
#                     (e.g. codex); empty = pane holds no agent
#   FAKE_AGENT_STATUS agent_status reported by `agent get`; default idle
#   FAKE_AGENT_GET_FAIL 1 makes `agent get` fail (probe inconclusive)
#   FAKE_AGENT_WAIT_FAIL 1 makes `agent wait` fail (submit never confirms)
#   CS_SEND_LOG       `pane run` appends its literal text argument here
cs_capo_fake_herdr() {
  local fakebin=$1
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "status --json") echo '{"server":{"running":true,"protocol":16,"socket":""}}' ;;
  "pane get")
    [ "${FAKE_PANE_EXISTS:-1}" = 1 ] || exit 1
    # Echo the requested pane id back, exactly as herdr 0.7.5 does. The
    # presence classifier (cs_herdr_pane_presence) reads a success body that
    # does NOT echo the id as `unknown`, so a body-less stand-in would make any
    # teardown in a capo suite refuse for the wrong reason.
    printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
  "agent get")
    [ "${FAKE_AGENT_GET_FAIL:-0}" = 1 ] && exit 1
    if [ -n "${FAKE_AGENT:-}" ]; then
      printf '{"result":{"agent":{"agent":"%s","agent_status":"%s"}}}\n' "$FAKE_AGENT" "${FAKE_AGENT_STATUS:-idle}"
    else
      echo '{"result":{"agent":{}}}'
    fi ;;
  "agent wait")
    # Mirror the pinned herdr 0.7.5: reject the pre-0.7.5 --status spelling. A
    # fake that accepts any flag is how the wrong flag shipped and stayed shipped.
    for _a in "$@"; do
      case "$_a" in
        --status|--status=*) echo "unknown option: --status" >&2; exit 2 ;;
      esac
    done
    [ "${FAKE_AGENT_WAIT_FAIL:-0}" = 1 ] && exit 1
    echo '{}' ;;
  "pane read") echo 'quiet prompt' ;;
  "pane run")
    if [ -n "${CS_SEND_LOG:-}" ]; then printf '%s' "${4:-}" >> "$CS_SEND_LOG"; fi
    echo '{}' ;;
  "pane send-text")
    if [ -n "${CS_SEND_LOG:-}" ]; then printf '%s' "${4:-}" >> "$CS_SEND_LOG"; fi
    echo '{}' ;;
  "pane send-keys") echo '{}' ;;
  "pane close") echo '{}' ;;
  *) echo '{}' ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
}
