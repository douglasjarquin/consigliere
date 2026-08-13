#!/usr/bin/env bash
# tests/cs-herdr-lab.test.sh - bin/cs-herdr-lab.sh: cs_herdr_lab_raw's --session
# placement relative to a subcommand's own "--" trailing-argv separator.
#
# Fully offline: a fake herdr CLI echoes its received argv, one per line, so
# assertions read exact flag order rather than any live session state.
# PATH is exported inside a deliberate `$(...)` subshell per case; the
# enclosing scope never needs to see it.
# shellcheck disable=SC2030,SC2031
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(cs_test_tmproot cs-herdr-lab)

make_fakebin() { # <dir>
  local fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do printf '%s\n' "$a"; done
SH
  chmod +x "$fakebin/herdr"
}

test_session_flag_appended_without_separator() {
  local dir got want
  dir="$TMP_ROOT/no-sep"; mkdir -p "$dir"
  make_fakebin "$dir"
  got=$(
    export PATH="$dir/fakebin:$PATH"
    # shellcheck source=bin/cs-herdr-lab.sh
    . "$ROOT/bin/cs-herdr-lab.sh"
    cs_herdr_lab_raw cs-lab-x pane list
  )
  want=$'pane\nlist\n--session\ncs-lab-x'
  [ "$got" = "$want" ] || { printf 'no-separator argv was:\n%s\nwant:\n%s\n' "$got" "$want" >&2; exit 1; }
  pass "no trailing -- separator: --session appended at the end, unchanged from before"
}

test_session_flag_precedes_trailing_separator() {
  local dir got want
  dir="$TMP_ROOT/with-sep"; mkdir -p "$dir"
  make_fakebin "$dir"
  got=$(
    export PATH="$dir/fakebin:$PATH"
    # shellcheck source=bin/cs-herdr-lab.sh
    . "$ROOT/bin/cs-herdr-lab.sh"
    cs_herdr_lab_raw cs-lab-x agent start probeagent --kind claude --pane w1:p1 -- --permission-mode auto
  )
  want=$'agent\nstart\nprobeagent\n--kind\nclaude\n--pane\nw1:p1\n--session\ncs-lab-x\n--\n--permission-mode\nauto'
  [ "$got" = "$want" ] || { printf 'trailing-separator argv was:\n%s\nwant:\n%s\n' "$got" "$want" >&2; exit 1; }
  pass "agent start's trailing -- ARG separator: --session lands before --, never swallowed as a literal agent arg (the bug this regresses)"
}

test_session_flag_precedes_trailing_separator
test_session_flag_appended_without_separator

pass "cs-herdr-lab.sh cs_herdr_lab_raw --session placement"
