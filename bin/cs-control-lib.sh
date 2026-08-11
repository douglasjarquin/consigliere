# shellcheck shell=bash
# cs-control-lib.sh - the agent-control plane's shared mechanics.
#
# Sourced, never executed. The verbs, their postconditions, and the relaunch
# journal live here so bin/cs-control.sh and bin/cs-spawn.sh --relaunch share one
# definition of "the agent stopped" and "the pane is sitting in that worktree"
# instead of each improvising its own.
#
# Requires, sourced first by the caller (the same contract bin/cs-prompt-lib.sh
# uses): bin/cs-herdr-lib.sh and bin/cs-harness-lib.sh for every function,
# bin/cs-meta-lib.sh for the journal, and bin/cs-composer-lib.sh for
# cs_control_exit (which flushes a composer holding unsent text with one Enter
# before typing its command; the flush comment below owns why).
#
# What this library deliberately does NOT do: remove a worktree, close a pane,
# delete a branch, or discard a change. Stopping an agent and destroying its work
# are different acts with different authority; bin/cs-teardown.sh owns the second
# one and its landed-work proofs.

# The complete verb list. There is no arbitrary-text and no raw-key verb: a
# caller either names one of these or is refused.
CS_CONTROL_VERBS='interrupt exit relaunch'

# Seconds to wait for each postcondition. Generous rather than tight: a wrong
# "not confirmed" sends recovery down the wrong path, and the only cost of
# waiting is a slower report.
CS_CONTROL_INTERRUPT_WAIT_SECS=${CS_CONTROL_INTERRUPT_WAIT_SECS:-15}
CS_CONTROL_EXIT_WAIT_SECS=${CS_CONTROL_EXIT_WAIT_SECS:-30}
# Pre-Enter settle for a harness whose completion popup would swallow an atomic
# Enter (cs_harness_composer_command_settle).
CS_CONTROL_EXIT_SETTLE=${CS_CONTROL_EXIT_SETTLE:-1.5}
# How long to let the composer settle after the one flush Enter below.
CS_CONTROL_FLUSH_SETTLE=${CS_CONTROL_FLUSH_SETTLE:-2}

cs_control_verb_valid() { # <verb>
  case " $CS_CONTROL_VERBS " in
    *" ${1:-} "*) [ -n "${1:-}" ] ;;
    *) return 1 ;;
  esac
}

# --- endpoint predicates -----------------------------------------------------

# The pid of the agent process occupying the pane, rc 1 when none is running or
# the process table could not be read. Identity, not liveness: a relaunch is
# proven by a DIFFERENT pid owning the pane, and that proof holds on both
# harnesses, unlike an agent session id (herdr reports none at all for codex
# 0.147 - docs/herdr.md).
cs_control_agent_pid() { # <pane_id> -> pid
  local out
  out=$(cs_herdr_pane_agent_process "$1") || return 1
  printf '%s\n' "${out%%	*}"
}

# 0 only when the pane is readable, its process table was read successfully, and
# no agent process is running in it. "Could not read it" is never proof, so this
# fails closed: cs_herdr_pane_is_agent_husk owns that distinction.
cs_control_agent_gone() { # <pane_id>
  cs_herdr_pane_is_agent_husk "$1"
}

# Is the pane's shell sitting in <dir>? rc 0 match, 1 mismatch, 2 unknown.
# Both sides are physically resolved, because herdr reports a resolved cwd
# (/private/var/... on macOS) and a recorded worktree path may be the symlinked
# spelling of the same directory.
cs_control_pane_in_dir() { # <pane_id> <dir>
  local pane=$1 dir=$2 cwd want
  cwd=$(cs_herdr_pane_cwd "$pane") || return 2
  cwd=$(cd "$cwd" 2>/dev/null && pwd -P) || return 2
  want=$(cd "$dir" 2>/dev/null && pwd -P) || return 2
  [ "$cwd" = "$want" ]
}

# --- verbs -------------------------------------------------------------------

# Cancel the running turn and leave the agent running. Prints one result token
# and returns 0 only for a verified postcondition:
#   already-idle   the agent is positively idle AND still in the pane; nothing
#                  was delivered
#   stopped        the turn stopped and the agent is still in the pane
#   blocked        native blocked: the agent waits on a human, not on a turn
#   still-working  the key was delivered and the turn did not stop
#   agent-gone     the pane holds no agent - a husk found before the key, or an
#                  agent that left with the turn; either way there is nothing
#                  running to interrupt or to steer afterwards
#   state-unknown  the agent's state could not be read; "cannot tell" is
#                  reported, never converted into an idle agent
# The key is delivered exactly ONCE. Codex reads a second Escape as "edit the
# previous message" and would leave the composer in a different mode, so an
# unconfirmed interrupt is reported rather than mashed.
cs_control_interrupt() { # <pane_id> <harness> -> token
  local pane=$1 harness=$2 key state waited=0
  state=$(cs_herdr_agent_busy_state "$pane" 2>/dev/null) || state=unknown
  case "$state" in
    blocked) printf 'blocked\n'; return 1 ;;
    busy) ;;
    *)
      # Not busy is only idempotent success when an agent is provably still
      # there to be idle. A husk pane and an unreadable state both land here,
      # and reporting either as "no turn was running" would send the caller
      # steering into an empty pane.
      if [ "$state" = idle ] || [ "$state" = 'done' ]; then
        if cs_herdr_agent_alive "$pane"; then
          printf 'already-idle\n'
          return 0
        fi
      fi
      if cs_control_agent_gone "$pane"; then
        printf 'agent-gone\n'
      else
        printf 'state-unknown\n'
      fi
      return 1
      ;;
  esac
  key=$(cs_harness_interrupt_key "$harness") || { printf 'unknown-harness\n'; return 1; }
  cs_herdr_send_keys "$pane" "$key" >/dev/null 2>&1 || { printf 'key-not-delivered\n'; return 1; }
  while [ "$waited" -lt "$CS_CONTROL_INTERRUPT_WAIT_SECS" ]; do
    sleep 1
    waited=$((waited + 1))
    state=$(cs_herdr_agent_busy_state "$pane" 2>/dev/null) || state=unknown
    case "$state" in
      busy) continue ;;
      blocked) printf 'blocked\n'; return 1 ;;
    esac
    # Not busy any more. Interrupt must leave the agent in the pane; if the
    # agent left with the turn, say so instead of reporting a clean interrupt.
    # An agent that merely cannot be read is neither: keep waiting within the
    # bound rather than claiming gone without the husk's positive evidence.
    if cs_herdr_agent_alive "$pane"; then
      printf 'stopped\n'
      return 0
    fi
    if cs_control_agent_gone "$pane"; then
      printf 'agent-gone\n'
      return 1
    fi
  done
  printf 'still-working\n'
  return 1
}

# Stop the agent, preserving the pane, its shell, the worktree, and every
# uncommitted change. Prints one result token; 0 only when the agent is
# positively gone:
#   already-gone       the pane held no agent when asked (idempotent success)
#   gone               the exit command was delivered and the agent left
#   command-not-sent   herdr refused the send
#   still-running      delivered, and an agent still occupies the pane
#
# THE FLUSH. Unsent composer text breaks a lifecycle command: typing onto it
# submits the concatenation as one prompt, which the agent reasons about instead
# of executing (measured, docs/claude.md). herdr has no key that CLEARS a
# composer (`C-u` is refused and a second interrupt key does not clear it), so the
# only way past it is to SUBMIT the line with one Enter and cancel the turn that
# starts. The content is almost always consigliere's own steer that arrived
# mid-turn and was queued, and the next step stops the agent anyway, so that
# costs one abandoned turn and nothing else.
#
# After that one flush the command is typed regardless of what the classifier
# still says, and the postcondition decides. Two measured reasons: text that
# survives an Enter is not unsent input, and the classifier reports `pending` for
# rows that only LOOK like a composer - a real soldier pane reads `pending` from
# its own shell prompt row before the agent has drawn its UI (docs/claude.md).
# Refusing on that reading blocked the exit verb on healthy soldiers, and a
# blocked recovery is worse than a wasted prompt: an unverified exit is reported
# honestly and a retry finds the composer empty.
cs_control_exit() { # <pane_id> <harness> -> token
  local pane=$1 harness=$2 cmd settle composer state waited attempt=0
  if cs_control_agent_gone "$pane"; then
    printf 'already-gone\n'
    return 0
  fi
  cmd=$(cs_harness_exit_command "$harness") || { printf 'unknown-harness\n'; return 1; }
  settle=$(cs_harness_composer_command_settle "$harness") || settle=0
  # Two attempts, because both the flush above and a turn that started between
  # the state read and the send leave the command QUEUED as input instead of
  # executed. A queued command is invisible in the pane state, so the only way to
  # tell is the postcondition: if the agent is taking a turn afterwards, cancel it
  # and type the command once more.
  while [ "$attempt" -lt 2 ]; do
    attempt=$((attempt + 1))
    # Never type into a running turn.
    state=$(cs_herdr_agent_busy_state "$pane" 2>/dev/null) || state=unknown
    if [ "$state" = busy ]; then
      cs_control_interrupt "$pane" "$harness" >/dev/null || true
      state=$(cs_herdr_agent_busy_state "$pane" 2>/dev/null) || state=unknown
      [ "$state" = busy ] && { printf 'still-running\n'; return 1; }
    fi
    composer=$(cs_composer_state "$pane" 2>/dev/null) || composer=unknown
    if [ "$composer" = pending ]; then
      cs_herdr_send_keys "$pane" Enter >/dev/null 2>&1 || { printf 'command-not-sent\n'; return 1; }
      sleep "$CS_CONTROL_FLUSH_SETTLE"
      state=$(cs_herdr_agent_busy_state "$pane" 2>/dev/null) || state=unknown
      if [ "$state" = busy ]; then
        cs_control_interrupt "$pane" "$harness" >/dev/null || true
      fi
      if cs_control_agent_gone "$pane"; then
        printf 'already-gone\n'
        return 0
      fi
    fi
    cs_herdr_send_text "$pane" "$cmd" >/dev/null 2>&1 || { printf 'command-not-sent\n'; return 1; }
    [ "$settle" = 1 ] && sleep "$CS_CONTROL_EXIT_SETTLE"
    cs_herdr_send_keys "$pane" Enter >/dev/null 2>&1 || { printf 'command-not-sent\n'; return 1; }
    waited=0
    while [ "$waited" -lt "$CS_CONTROL_EXIT_WAIT_SECS" ]; do
      sleep 1
      waited=$((waited + 1))
      if cs_control_agent_gone "$pane"; then
        printf 'gone\n'
        return 0
      fi
    done
  done
  printf 'still-running\n'
  return 1
}

# Interrupt a mid-turn agent, then exit it. Prints "<interrupt-token> <exit-token>"
# and returns 0 only when the exit postcondition holds. An agent taking a turn
# never reads a composer command as a command - it queues as input - so the
# interrupt is part of stopping, not a separate courtesy.
cs_control_stop() { # <pane_id> <harness> -> "<interrupt-token> <exit-token>"
  local pane=$1 harness=$2 itok etok irc=0
  itok=$(cs_control_interrupt "$pane" "$harness") || irc=$?
  case "$itok" in
    already-idle|stopped) ;;
    agent-gone)
      # The pane holds no agent - a husk, or an agent that left with the turn.
      # The exit postcondition is already met, and relaunching a husk is the
      # main recovery case this plane exists for, so the exit verb still runs
      # and confirms it rather than reporting exit-not-attempted.
      etok=$(cs_control_exit "$pane" "$harness") || true
      printf '%s %s\n' "$itok" "$etok"
      case "$etok" in already-gone|gone) return 0 ;; *) return 1 ;; esac
      ;;
    *)
      printf '%s exit-not-attempted\n' "$itok"
      return "${irc:-1}"
      ;;
  esac
  etok=$(cs_control_exit "$pane" "$harness") || true
  printf '%s %s\n' "$itok" "$etok"
  case "$etok" in already-gone|gone) return 0 ;; *) return 1 ;; esac
}

# --- relaunch journal --------------------------------------------------------
# One flat key=value file per task, in the same format and with the same
# last-occurrence-wins rule as state/<id>.meta, so bin/cs-meta-lib.sh reads and
# writes it and the format has one owner. docs/agent-control.md owns the phase
# sequence; bin/cs-control.sh --help owns the fields.

cs_control_journal_path() { # <state-dir> <id>
  printf '%s/%s.control-relaunch\n' "$1" "$2"
}

# Where a superseded journal is kept for post-mortem when --clear-journal
# acknowledges an interrupted transaction. One slot: the newest supersession is
# the one worth keeping.
cs_control_journal_abandoned_path() { # <state-dir> <id>
  printf '%s/%s.control-relaunch.abandoned\n' "$1" "$2"
}

cs_control_journal_phase() { # <journal> -> phase, rc 1 when unreadable
  cs_meta_get "$1" phase
}

# 0 when <phase> ended its transaction. A journal left in any other phase means
# the process running it died mid-transaction, which the next relaunch must
# report rather than launch over.
cs_control_journal_terminal() { # <phase>
  case "${1:-}" in
    done|failed) return 0 ;;
    *) return 1 ;;
  esac
}
