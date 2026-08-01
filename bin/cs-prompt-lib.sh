#!/usr/bin/env bash
# cs-prompt-lib.sh - the one guarded way to make an agent take a turn.
#
# Sourced, never executed. Requires cs-herdr-lib.sh and cs-composer-lib.sh to be
# sourced first.
#
# Every path that puts text into an agent's pane needs the same four guards, and
# they were previously written once inside the away daemon and nowhere else. A
# second caller (per-home activation, bin/cs-activate.sh) would have copied them,
# so they live here instead:
#
#   1. pane exists;
#   2. busy-guard  - never prompt a mid-turn (`busy`) or human-blocked pane;
#   3. composer-guard - only an affirmatively EMPTY composer is a safe target;
#   4. submit confirmation - the agent must actually enter `working`.
#
# WHY THE COMPOSER GUARD SURVIVES, measured 2026-08-01 in an isolated lab:
# `herdr agent prompt` CONCATENATES its text onto whatever is already in the
# composer and submits the merged line, reporting success. So does `pane run`.
# Typing "HUMAN_HALF_TYPED_LINE" and then prompting "ZZMARKER_THREE" submitted
# `HUMAN_HALF_TYPED_LINEZZMARKER_THREE` as one message, on both codex and claude.
# Concatenation is a property of every submit path, not of any one primitive, so
# no primitive change can retire this guard.
#
# WHY SUBMIT CONFIRMATION SURVIVES: `agent prompt` returns `agent_prompted` and
# exit 0 for a prompt that was never delivered. Measured on both harnesses: a
# prompt sent within ~40s of `agent start` is silently lost while herdr reports
# `agent_status: idle` and `interactive_ready: true`. Only the idle->working
# transition proves a turn began.
#
# WHY `agent prompt` RATHER THAN send-text + Enter: it is atomic (no swallowed
# Enter, so no retype-vs-retry hazard) and it delivers MULTILINE text as ONE
# message - verified; a three-line prompt arrived intact with no premature
# submit on the first newline. Daemon digests are multiline.
#
# The U+2063 operational-input marker survives `agent prompt` intact (verified
# byte-level: the receiving agent reported a leading e2 81 a3), so the
# away-supervisor typing contract is unaffected.

# cs_prompt_guarded <pane> <text> [log-fn]
# 0 = a turn provably started. 1 = not delivered; the reason went to log-fn.
cs_prompt_guarded() {
  local pane=$1 text=$2 logfn=${3:-:} bs composer wait_ms

  cs_herdr_pane_exists "$pane" || { "$logfn" "prompt deferred: pane '$pane' is gone"; return 1; }

  bs=$(cs_herdr_agent_busy_state "$pane" 2>/dev/null) || bs=unknown
  case "$bs" in
    busy|blocked)
      "$logfn" "prompt deferred: pane busy (agent state=$bs)"
      return 1 ;;
  esac

  composer=$(cs_composer_state "$pane" 2>/dev/null)
  if [ "$composer" != empty ]; then
    "$logfn" "prompt deferred: composer not confirmed-empty (state=${composer:-unknown}); prompting now would concatenate onto it"
    return 1
  fi

  if ! cs_herdr_agent_prompt "$pane" "$text" >/dev/null 2>&1; then
    "$logfn" "prompt failed: herdr rejected the prompt for '$pane' (no agent there?)"
    return 1
  fi

  # `agent_prompted` is not delivery. Require the turn.
  wait_ms=${CS_PROMPT_CONFIRM_WAIT_MS:-8000}
  if cs_herdr_submit_confirm "$pane" "$wait_ms"; then
    return 0
  fi
  "$logfn" "prompt unconfirmed: no idle->working transition within ${wait_ms}ms (agent may not have been ready)"
  return 1
}
