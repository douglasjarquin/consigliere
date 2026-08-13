#!/usr/bin/env bash
# tests/control-helpers.sh - fixtures and the fake herdr for the agent-control
# suites (cs-control and cs-control-relaunch).
#
# These mocks encode LIFECYCLE behavior - an agent that leaves the pane when the
# exit command is submitted, a turn that stops (or does not) on the interrupt
# key, a pane whose process table cannot be read - so they live here rather than
# in the generic tests/lib.sh, exactly as tests/capo-helpers.sh does for the capo
# paths. The generic git/meta/assertion primitives come from lib.sh.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# cs_control_fake_herdr <fakebin> - a fake herdr driven by a mutable state
# DIRECTORY, because every control verb is a state transition: the answer before
# the key or command is delivered has to differ from the answer after it.
#
# State files under $FAKE_STATE (all optional, sensible defaults):
#   pane_absent    non-empty: `pane get` answers pane_not_found
#   pane_garbage   non-empty: `pane get` answers non-JSON (unreachable server)
#   agent          agent name reported by `agent get` and the process table;
#                  empty or missing = no agent in the pane
#   status         agent_status; default idle
#   pid            agent process pid; default 4242
#   session        agent_session.value; empty = unreported
#   cwd            pane cwd; empty = unreported
#   composer       the composer row `pane read` renders; default codex's
#                  empty glyph (this fixture's agent is codex throughout)
#   procinfo_fail  non-empty: `pane process-info` fails (table unreadable), so
#                  the husk predicate must refuse rather than report a husk
#   proc_absent    non-empty: the process table is readable but holds NO agent
#                  process even while `agent get` still reports one - the
#                  stale-belief husk shape a real exited agent can leave behind
#   on_esc         `idle` sets status=idle when Escape arrives; `gone` removes
#                  the agent; `unknown` sets status=unknown (the uncorroborated
#                  reading a transient herdr failure yields); `blocked` sets
#                  status=blocked (the turn parked on a harness dialog instead
#                  of cancelling); absent leaves the state alone
#   on_enter       `gone` removes the agent when Enter arrives; `busy` sets
#                  status=working; `blocked` sets status=blocked (the turn the
#                  Enter submitted parked on a harness dialog); absent leaves
#                  the state alone
#   on_enter_composer  the composer row Enter leaves behind, which is how a
#                  flushed composer is modelled (an Enter submits the line and
#                  the composer comes back empty)
#   gone_at_enter  the Enter number that removes the agent, so a fixture can tell
#                  the flush Enter apart from the exit command's Enter
#   on_run         which `agent start` call brings an agent up: `up` = the
#                  first (the resume succeeded), `second` = only the second
#                  (nothing was resumable, so the cold launch is what starts
#                  an agent), absent = none ever comes up. cs-spawn.sh's
#                  relaunch triggers a resume via a fire-and-forget `agent
#                  start` (its own result discarded) and, only if the
#                  process-table loop below never sees it stabilize, a
#                  cold-launch `agent start` whose result DOES gate the spawn.
#   run_agent      the agent name a launch brings up; default codex
#   run_pid        the pid a launch brings up; default the current pid + 1, so a
#                  relaunch's process-identity proof passes. Set it equal to
#                  `pid` to model a pane that never actually changed hands.
#   run_session    the agent_session.value a launch brings up; absent leaves the
#                  recorded one, which is what a real RESUME does
#   starts         written by the fake: how many `agent start` calls it has
#                  seen (separate from `runs`, which still counts `pane run` -
#                  the env-export pre-step's mechanism, unrelated to launching)
#   runs           written by the fake: how many `pane run` calls it has seen
#   log            every call is appended here as one line
cs_control_fake_herdr() {
  local fakebin=$1
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
S=${FAKE_STATE:?FAKE_STATE must be set}
read_state() { cat "$S/$1" 2>/dev/null || true; }
log() { [ -n "$(read_state log)" ] && printf '%s\n' "$*" >> "$(read_state log)"; return 0; }
log "$*"
case "$1 $2" in
  "status --json") echo '{"server":{"running":true,"protocol":17,"socket":""}}' ;;
  "pane get")
    if [ -n "$(read_state pane_garbage)" ]; then
      echo 'Error: Os { code: 2, kind: NotFound }' >&2; exit 1
    fi
    if [ -n "$(read_state pane_absent)" ]; then
      printf '{"error":{"code":"pane_not_found","message":"pane %s not found"}}\n' "$3" >&2; exit 1
    fi
    printf '{"result":{"pane":{"pane_id":"%s","cwd":"%s","foreground_cwd":"%s"}}}\n' \
      "$3" "$(read_state cwd)" "$(read_state cwd)"
    ;;
  "agent get")
    if [ -z "$(read_state agent)" ]; then
      printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "$3" >&2; exit 1
    fi
    status=$(read_state status)
    [ -n "$status" ] || status=idle
    printf '{"result":{"agent":{"agent":"%s","agent_status":"%s","agent_session":{"value":"%s"}}}}\n' \
      "$(read_state agent)" "$status" "$(read_state session)"
    ;;
  "agent wait") echo '{}' ;;
  "pane process-info")
    [ -n "$(read_state procinfo_fail)" ] && exit 1
    if [ -z "$(read_state agent)" ] || [ -n "$(read_state proc_absent)" ]; then
      printf '{"result":{"process_info":{"shell_pid":10,"foreground_processes":[]}}}\n'
    else
      pid=$(read_state pid)
      case "$pid" in ''|*[!0-9]*) pid=4242 ;; esac
      printf '{"result":{"process_info":{"shell_pid":10,"foreground_processes":[{"pid":%s,"argv0":"%s","cwd":"%s"}]}}}\n' \
        "$pid" "$(read_state agent)" "$(read_state cwd)"
    fi
    ;;
  "pane read")
    composer=$(read_state composer)
    # Codex's actual empty-composer glyph (a bare ❯ alone does not classify as
    # empty to cs_composer_state - nothing in this suite exercised that verdict
    # before bin/cs-spawn.sh's post-launch brief delivery, _cs_spawn_deliver_brief,
    # which bypasses cs_prompt_guarded, started reading this pane).
    [ -n "$composer" ] || composer=$'\342\200\272 '
    printf 'some transcript line\n%s\n' "$composer"
    ;;
  "pane send-keys")
    # herdr's form is `pane send-keys <pane> <key>...`, so the key is $4.
    case "${4:-}" in
      esc|Escape|escape)
        case "$(read_state on_esc)" in
          idle) printf 'idle\n' > "$S/status" ;;
          gone) : > "$S/agent" ;;
          unknown) printf 'unknown\n' > "$S/status" ;;
          blocked) printf 'blocked\n' > "$S/status" ;;
        esac
        ;;
      Enter)
        enters=$(read_state enters)
        case "$enters" in ''|*[!0-9]*) enters=0 ;; esac
        enters=$((enters + 1))
        printf '%s\n' "$enters" > "$S/enters"
        newcomposer=$(read_state on_enter_composer)
        [ -n "$newcomposer" ] && printf '%s\n' "$newcomposer" > "$S/composer"
        gone_at=$(read_state gone_at_enter)
        [ -n "$gone_at" ] && [ "$enters" -ge "$gone_at" ] && : > "$S/agent"
        case "$(read_state on_enter)" in
          gone) : > "$S/agent" ;;
          busy) printf 'working\n' > "$S/status" ;;
          blocked) printf 'blocked\n' > "$S/status" ;;
        esac
        ;;
    esac
    echo '{}'
    ;;
  "pane send-text") echo '{}' ;;
  "pane wait-output") echo '{}' ;;
  "agent start")
    starts=$(read_state starts)
    case "$starts" in ''|*[!0-9]*) starts=0 ;; esac
    starts=$((starts + 1))
    printf '%s\n' "$starts" > "$S/starts"
    bring_up=0
    case "$(read_state on_run)" in
      up) [ "$starts" -ge 1 ] && bring_up=1 ;;
      second) [ "$starts" -ge 2 ] && bring_up=1 ;;
    esac
    if [ "$bring_up" = 1 ]; then
      agent=$(read_state run_agent)
      [ -n "$agent" ] || agent=codex
      printf '%s\n' "$agent" > "$S/agent"
      printf 'idle\n' > "$S/status"
      newpid=$(read_state run_pid)
      if [ -z "$newpid" ]; then
        newpid=$(read_state pid)
        case "$newpid" in ''|*[!0-9]*) newpid=4242 ;; esac
        newpid=$((newpid + 1))
      fi
      printf '%s\n' "$newpid" > "$S/pid"
      newsession=$(read_state run_session)
      [ -n "$newsession" ] && printf '%s\n' "$newsession" > "$S/session"
      printf '{"result":{"agent":{"agent":"%s","agent_status":"idle","interactive_ready":true}}}\n' "$agent"
    else
      printf '{"error":{"code":"agent_not_ready","message":"timed out"}}\n' >&2
      exit 1
    fi
    ;;
  "pane run")
    runs=$(read_state runs)
    case "$runs" in ''|*[!0-9]*) runs=0 ;; esac
    runs=$((runs + 1))
    printf '%s\n' "$runs" > "$S/runs"
    bring_up=0
    case "$(read_state on_run)" in
      up) [ "$runs" -ge 1 ] && bring_up=1 ;;
      second) [ "$runs" -ge 2 ] && bring_up=1 ;;
    esac
    if [ "$bring_up" = 1 ]; then
      agent=$(read_state run_agent)
      [ -n "$agent" ] || agent=codex
      printf '%s\n' "$agent" > "$S/agent"
      printf 'idle\n' > "$S/status"
      newpid=$(read_state run_pid)
      if [ -z "$newpid" ]; then
        newpid=$(read_state pid)
        case "$newpid" in ''|*[!0-9]*) newpid=4242 ;; esac
        newpid=$((newpid + 1))
      fi
      printf '%s\n' "$newpid" > "$S/pid"
      newsession=$(read_state run_session)
      [ -n "$newsession" ] && printf '%s\n' "$newsession" > "$S/session"
    fi
    echo '{}'
    ;;
  *) echo '{}' ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
}

# cs_control_state <dir> [key=value...] - create a fake-herdr state directory
# and echo its path. Every key becomes a one-line file.
cs_control_state() {
  local dir=$1 kv key
  shift
  mkdir -p "$dir"
  for kv in "$@"; do
    key=${kv%%=*}
    printf '%s\n' "${kv#*=}" > "$dir/$key"
  done
  printf '%s\n' "$dir"
}

# cs_control_set <state-dir> <key> <value> - overwrite one state file.
cs_control_set() {
  printf '%s\n' "$3" > "$1/$2"
}
