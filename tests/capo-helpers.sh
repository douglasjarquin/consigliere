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
# <sandbox>/<name>-remote.git. Register it in data/projects.md yourself.
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
    echo '{"result":{"pane":{}}}' ;;
  "agent get")
    [ "${FAKE_AGENT_GET_FAIL:-0}" = 1 ] && exit 1
    if [ -n "${FAKE_AGENT:-}" ]; then
      printf '{"result":{"agent":{"agent":"%s","agent_status":"%s"}}}\n' "$FAKE_AGENT" "${FAKE_AGENT_STATUS:-idle}"
    else
      echo '{"result":{"agent":{}}}'
    fi ;;
  "agent wait")
    # Reject --status exactly as the real binary does. A fake that accepts any
    # flag is how a wrong flag shipped and stayed shipped: submit confirmation
    # failed against real herdr for every steer while every test passed.
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
