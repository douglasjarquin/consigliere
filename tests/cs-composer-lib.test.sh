#!/usr/bin/env bash
# tests/cs-composer-lib.test.sh - bin/cs-composer-lib.sh: agent composer
# emptiness classification (codex › and claude ❯) from an ANSI pane capture.
# Load-bearing via bin/cs-prompt-lib.sh's composer guard, shared by every
# guarded-prompt caller (bin/cs-activate.sh today).
#
# Fully offline: a fake herdr CLI answers only the two subcommands
# cs_composer_state actually calls (pane read for the capture, pane
# process-info for the no-agent-process corroboration).
# The locale sweep below sets LC_ALL inside a deliberate `$(...)` subshell per
# iteration; the outer shell never needs to see it.
# shellcheck disable=SC2030,SC2031
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(cs_test_tmproot cs-composer-lib)

# make_case <name>: case dir with a fakebin/herdr driven by env:
#   CS_FAKE_HERDR_CAPTURE       file whose contents `pane read` prints
#   CS_FAKE_HERDR_AGENT_PROC    process-info foreground argv0 (default claude;
#                               "none" leaves only a bare shell, the husk a
#                               crashed agent leaves)
make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"; fakebin="$dir/fakebin"
  mkdir -p "$dir" "$fakebin"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "pane read")
    if [ -n "${CS_FAKE_HERDR_CAPTURE:-}" ]; then
      cat "$CS_FAKE_HERDR_CAPTURE" 2>/dev/null
    fi
    exit 0 ;;
  "agent get")
    # Unset = no native status (agent get fails), matching a herdr that cannot
    # answer; a value is served as the pane's native agent_status.
    [ -n "${CS_FAKE_HERDR_AGENT_STATUS:-}" ] || exit 1
    printf '{"result":{"agent":{"agent":"claude","agent_status":"%s"}}}\n' \
      "$CS_FAKE_HERDR_AGENT_STATUS"
    exit 0 ;;
  "pane process-info")
    if [ "${CS_FAKE_HERDR_AGENT_PROC:-claude}" = none ]; then
      printf '{"result":{"process_info":{"shell_pid":100,"foreground_processes":[{"pid":100,"argv0":"zsh"}]}}}\n'
    else
      printf '{"result":{"process_info":{"shell_pid":100,"foreground_processes":[{"pid":200,"argv0":"%s"}]}}}\n' \
        "${CS_FAKE_HERDR_AGENT_PROC:-claude}"
    fi
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$dir"
}

test_composer_classifier() {
  local dir cap cap2 verdict utf8loc loc
  dir=$(make_case composer-unit); cap="$dir/cap.txt"
  cap2="$dir/cap2.txt"
  (
    cd "$dir" || exit 1
    export PATH="$dir/fakebin:$PATH" CS_FAKE_HERDR_CAPTURE="$cap"
    # Rows captured verbatim from a live claude 2.1.227 pane in an isolated
    # herdr lab (2026-08-11; the same capture docs/claude.md records). Claude
    # draws its composer between 53-column rules, and the empty composer row is
    # `❯` + U+00A0, NOT `❯` + a plain space.
    RULE=$(printf '\033[0m\033[38;2;136;136;136m%s\033[0m\r' \
      "$(printf '\342\224\200%.0s' $(seq 1 53))")
    CLAUDE_EMPTY_ROW=$(printf '\342\235\257\302\240\r')
    CLAUDE_HINTS=$(printf '  \033[0m\033[38;2;255;193;7m\342\232\240 Transcript saving is off\033[0m\r')
    # The zsh prompt the same pane showed after the agent exited: a path/duration
    # row, then `❯` ALONE on its own row - the same U+276F claude uses, at a
    # 256-colour foreground. Only the path text is substituted; every SGR code,
    # row split, and glyph is as captured.
    ZSH_PROMPT=$(printf '\033[0m\033[38;5;4mpane-cwd\033[0m \033[0m\033[38;5;3m14s\033[0m \r\n\033[0m\033[38;5;5m\342\235\257\033[0m ')
    # shellcheck source=bin/cs-herdr-lib.sh
    . "$ROOT/bin/cs-herdr-lib.sh"
    # shellcheck source=bin/cs-composer-lib.sh
    . "$ROOT/bin/cs-composer-lib.sh"
    # Empty codex composer: bare › prompt with a DIM (SGR 2) ghost suggestion.
    printf 'transcript above\n\342\200\272 \033[2mTry "fix the failing test"\033[0m\n' > "$cap"
    verdict=$(cs_composer_state w1:p1)
    [ "$verdict" = empty ] || { echo "ghost-only codex composer read '$verdict', want empty" >&2; exit 1; }
    # Real typed input after the prompt is pending.
    printf '\342\200\272 land the PR now\n' > "$cap"
    verdict=$(cs_composer_state w1:p1)
    [ "$verdict" = pending ] || { echo "typed input read '$verdict', want pending" >&2; exit 1; }
    # ANSI stripped by the transport: ghost text arrives as plain bytes and
    # must classify pending (the documented fail-toward-defer direction).
    printf '\342\200\272 \033[2m\033[0m\n' > "$cap"; :
    printf '\342\200\272 Try "fix the failing test"\n' > "$cap"
    verdict=$(cs_composer_state w1:p1)
    [ "$verdict" = pending ] || { echo "ANSI-stripped ghost read '$verdict', want pending (defer)" >&2; exit 1; }
    # A bare dead-shell prompt is never a composer: unknown.
    printf '$ \n' > "$cap"
    verdict=$(cs_composer_state w1:p1)
    [ "$verdict" = unknown ] || { echo "bare shell prompt read '$verdict', want unknown" >&2; exit 1; }
    # A bordered box with only its own shell glyph is an empty agent composer.
    printf '\342\224\202 > \342\224\202\n' > "$cap"
    verdict=$(cs_composer_state w1:p1)
    [ "$verdict" = empty ] || { echo "bordered empty composer read '$verdict', want empty" >&2; exit 1; }
    # Claude empty composer: the ❯ (U+276F) row between claude's own horizontal
    # rules, no ghost text. The rules are what prove it is a composer at all.
    printf '%s\n%s\n%s\n%s\n' "$RULE" "$CLAUDE_EMPTY_ROW" "$RULE" "$CLAUDE_HINTS" > "$cap"
    verdict=$(cs_composer_state w1:p1)
    [ "$verdict" = empty ] || { echo "empty claude composer read '$verdict', want empty" >&2; exit 1; }
    # THE BUG (reproduced from real bytes): the agent exited to a login shell,
    # whose prompt glyph is the same ❯. Nothing here is an agent composer, so
    # this must NEVER be empty - typing into it would EXECUTE the digest.
    printf '%s\n' "$ZSH_PROMPT" > "$cap"
    verdict=$(cs_composer_state w1:p1)
    [ "$verdict" != empty ] \
      || { echo "dead-shell ❯ read 'empty'; that authorizes injection into a live shell" >&2; exit 1; }
    [ "$verdict" = unknown ] || { echo "dead-shell ❯ read '$verdict', want unknown" >&2; exit 1; }
    # Worst case: claude's own composer is STILL in the scrollback above that
    # shell prompt. The stale composer must not be read as the live one.
    printf '%s\n%s\n%s\n%s\n' "$RULE" "$CLAUDE_EMPTY_ROW" "$RULE" "$ZSH_PROMPT" > "$cap"
    verdict=$(cs_composer_state w1:p1)
    [ "$verdict" = unknown ] \
      || { echo "stale composer above a dead shell read '$verdict', want unknown" >&2; exit 1; }
    # Corroboration layer: composer-shaped bytes but no agent process in the
    # pane (the husk a crashed agent leaves) still defers.
    printf '%s\n%s\n%s\n' "$RULE" "$CLAUDE_EMPTY_ROW" "$RULE" > "$cap"
    verdict=$(export CS_FAKE_HERDR_AGENT_PROC=none; cs_composer_state w1:p1)
    [ "$verdict" = unknown ] \
      || { echo "empty composer shape with no agent process read '$verdict', want unknown" >&2; exit 1; }
    # Claude typed input in that same composer is pending.
    printf '%s\n\342\235\257\302\240land the PR now\r\n%s\n' "$RULE" "$RULE" > "$cap"
    verdict=$(cs_composer_state w1:p1)
    [ "$verdict" = pending ] || { echo "typed claude input read '$verdict', want pending" >&2; exit 1; }
    # Unreadable/blank pane: unknown.
    : > "$cap"
    verdict=$(cs_composer_state w1:p1)
    [ "$verdict" = unknown ] || { echo "blank pane read '$verdict', want unknown" >&2; exit 1; }
    # NBSP (U+00A0, bytes C2 A0) padding after a bare ❯ is still an EMPTY claude
    # composer, and must read empty under a UTF-8 locale AND under LC_ALL=C,
    # where bash's [[:space:]] does not match it.
    utf8loc=$(locale -a 2>/dev/null | grep -iE '^(C|en_US)\.(utf-?8)$' | head -1)
    printf '%s\n\342\235\257\302\240\302\240\r\n%s\n' "$RULE" "$RULE" > "$cap"
    for loc in ${utf8loc:+"$utf8loc"} C; do
      verdict=$(export LC_ALL="$loc"; cs_composer_state w1:p1)
      [ "$verdict" = empty ] \
        || { echo "NBSP-padded empty claude composer read '$verdict' under LC_ALL=$loc, want empty" >&2; exit 1; }
      # NBSP separating real typed content still leaves content: pending.
      printf '%s\n\342\235\257\302\240land\302\240the PR now\r\n%s\n' "$RULE" "$RULE" > "$cap2"
      verdict=$(export LC_ALL="$loc" CS_FAKE_HERDR_CAPTURE="$cap2"; cs_composer_state w1:p1)
      [ "$verdict" = pending ] \
        || { echo "NBSP-separated typed input read '$verdict' under LC_ALL=$loc, want pending" >&2; exit 1; }
    done
    # REGRESSION (ported upstream fix, firstmate #2811): a BLOCKED agent -
    # parked on a permission prompt, trust dialog, or question menu - can draw
    # a blank composer region, so structure alone looks free. A blocked native
    # status must never yield the empty verdict that authorizes typing: the
    # keys would answer the dialog, not compose a message.
    printf '%s\n%s\n%s\n%s\n' "$RULE" "$CLAUDE_EMPTY_ROW" "$RULE" "$CLAUDE_HINTS" > "$cap"
    verdict=$(export CS_FAKE_HERDR_AGENT_STATUS=blocked; cs_composer_state w1:p1)
    [ "$verdict" = unknown ] \
      || { echo "blocked agent with empty-looking claude composer read '$verdict', want unknown" >&2; exit 1; }
    printf '\342\224\202 > \342\224\202\n' > "$cap"
    verdict=$(export CS_FAKE_HERDR_AGENT_STATUS=blocked; cs_composer_state w1:p1)
    [ "$verdict" = unknown ] \
      || { echo "blocked agent with bordered empty composer read '$verdict', want unknown" >&2; exit 1; }
    # An idle native status leaves the structural empty proof in charge, so
    # ordinary steering is unchanged.
    printf '%s\n%s\n%s\n%s\n' "$RULE" "$CLAUDE_EMPTY_ROW" "$RULE" "$CLAUDE_HINTS" > "$cap"
    verdict=$(export CS_FAKE_HERDR_AGENT_STATUS=idle; cs_composer_state w1:p1)
    [ "$verdict" = empty ] \
      || { echo "idle agent with empty claude composer read '$verdict', want empty" >&2; exit 1; }
    # A blocked agent demotes only the empty verdict; leftover text stays
    # pending so pre-exit flush callers keep working.
    printf '%s\n\342\235\257\302\240land the PR now\r\n%s\n' "$RULE" "$RULE" > "$cap"
    verdict=$(export CS_FAKE_HERDR_AGENT_STATUS=blocked; cs_composer_state w1:p1)
    [ "$verdict" = pending ] \
      || { echo "blocked agent with typed input read '$verdict', want pending" >&2; exit 1; }
  ) || fail "composer classifier verdicts wrong"
  pass "composer classifier (codex › and claude ❯): ghost-empty, typed-pending, stripped-transport-pending, dead-shell-unknown, bordered-empty, NBSP-padded-empty under UTF-8 and LC_ALL=C, and on real claude 2.1.227 bytes - live composer empty, exited-to-shell ❯ never empty, stale composer above a shell unknown, composer shape without an agent process unknown, blocked agent never empty (idle stays empty, typed input stays pending)"
}

test_composer_classifier

pass "cs-composer-lib.sh composer emptiness classification"
