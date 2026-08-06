# shellcheck shell=bash
# cs-deps-lib.sh - the single owner of consigliere's dependency inventory.
#
# Two consumers ask this library what consigliere depends on:
#   bin/cs-bootstrap.sh   in-session detection (MISSING / BOOTSTRAP_INFO lines)
#   bin/cs-doctor.sh      the human preflight report, before a first session
# Keeping the inventory in one place means a new dependency is added once and
# both the in-session gate and the preflight report learn about it together.
#
# Classes:
#   required      absent = consigliere cannot operate and must not dispatch.
#   optional      absent = one named capability is unavailable; the rest works.
#   contributor   absent = only the contributor workflow (lint, herdr push
#                 events) is affected. This class is deliberately NOT part of
#                 session-start detection, so bootstrap's output does not change
#                 when it grows.
#
# Version floors are NOT owned here. The pinned herdr version lives in
# bin/cs-install-herdr.sh, the herdr protocol floor in bin/cs-herdr-lib.sh
# (CS_HERDR_MIN_PROTOCOL), the ShellCheck pin in bin/cs-lint.sh
# (--required-version), and the axi-family floors and their bump policy in
# bin/cs-bootstrap.sh. This library names tools, states why consigliere needs
# them, probes the installed version, offers the version comparison the floor
# owners share, and suggests an install channel - it never holds a second copy
# of a pin.
#
# Install suggestions are suggestions only. Consigliere never installs a
# dependency for the boss: the same tool legitimately arrives by brew, npm, a
# native installer, or a hand-built binary depending on the machine, and this
# repo has no business overriding that choice.
#
# Usage:
#   # shellcheck source=bin/cs-deps-lib.sh
#   . "$SCRIPT_DIR/cs-deps-lib.sh"
#   cs_deps_tools required|optional|contributor   # one tool name per line
#   cs_deps_purpose <tool>                        # why consigliere needs it
#   cs_deps_hint <tool>                           # install suggestion
#   cs_deps_version <tool>                        # installed version, or nothing
#   cs_deps_version_at_least <tool> <floor>       # exit 0 iff installed >= floor
#
# cs_deps_version runs the tool's own `--version`; it does not bound that call,
# so it is only safe against the inventory's tools, never arbitrary input.

# Idempotent guard: sourcing twice must not redefine the functions.
if [ -n "${CS_DEPS_LIB_SOURCED:-}" ]; then
  return 0
fi
CS_DEPS_LIB_SOURCED=1

CS_DEPS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The required harness is the ROOT session's own; cs-harness-lib.sh owns that
# resolution, so the inventory never second-guesses which harness is required.
# shellcheck source=bin/cs-harness-lib.sh
. "$CS_DEPS_LIB_DIR/cs-harness-lib.sh"

# cs_deps_root_harness_binary - executable name of the ROOT session's harness.
cs_deps_root_harness_binary() {
  cs_harness_binary "$(cs_harness_detect_root)"
}

# cs_deps_other_harness_binary - the harness that is NOT the root session's.
cs_deps_other_harness_binary() {
  if [ "$(cs_deps_root_harness_binary)" = codex ]; then
    printf 'claude\n'
  else
    printf 'codex\n'
  fi
}

# cs_deps_tools <class> - print the class's tool names, one per line.
# The required and optional orders are the order both consumers report in.
cs_deps_tools() {
  case "${1:-}" in
    required)
      printf '%s\n' herdr "$(cs_deps_root_harness_binary)" jq gh gh-axi git
      ;;
    optional)
      printf '%s\n' "$(cs_deps_other_harness_binary)" tasks-axi no-mistakes \
        lavish-axi chrome-devtools-axi quota-axi
      ;;
    contributor)
      printf '%s\n' shellcheck python3
      ;;
    *)
      printf 'cs-deps-lib: unknown class "%s"\n' "${1:-}" >&2
      return 1
      ;;
  esac
}

# cs_deps_purpose <tool> - one line on what consigliere loses without it.
cs_deps_purpose() {
  case "$1" in
    herdr) printf 'terminal runtime; every soldier runs in a herdr workspace/worktree\n' ;;
    codex) printf 'harness that runs consigliere and its soldiers\n' ;;
    claude) printf 'harness that runs consigliere and its soldiers\n' ;;
    jq) printf 'parses every herdr JSON response\n' ;;
    gh) printf 'GitHub auth and API for PR-based delivery\n' ;;
    gh-axi) printf 'the GitHub interface consigliere and its soldiers actually call\n' ;;
    git) printf 'clones, worktrees, branches, and every landing check\n' ;;
    tasks-axi) printf 'backlog backend; without it the backlog is hand-edited (config/backlog-backend.conf)\n' ;;
    no-mistakes) printf 'delivery pipeline for no-mistakes projects; other delivery modes are unaffected\n' ;;
    lavish-axi) printf 'visual review surfaces for structured decisions and reports\n' ;;
    chrome-devtools-axi) printf 'browser work for soldiers that must drive a real page\n' ;;
    quota-axi) printf 'local provider quota headroom before spending a quota window\n' ;;
    shellcheck) printf 'the required shell-lint check (bin/cs-lint.sh)\n' ;;
    python3) printf 'herdr push events (bin/cs-herdr-events.py); the watcher poll loop is the backstop\n' ;;
    *) printf 'no recorded purpose\n'; return 1 ;;
  esac
}

# cs_deps_hint <tool> - install suggestion. A suggestion, never a command this
# repo runs; pick whichever channel matches how the machine is already set up.
cs_deps_hint() {
  case "$1" in
    herdr) printf 'brew install herdr, or bin/cs-install-herdr.sh <dir> for CI'\''s pinned build (https://herdr.dev)\n' ;;
    codex) printf 'brew install --cask codex, or npm i -g @openai/codex\n' ;;
    claude) printf 'npm i -g @anthropic-ai/claude-code, or the native installer (https://claude.com/claude-code)\n' ;;
    jq) printf 'brew install jq (https://jqlang.github.io/jq)\n' ;;
    gh) printf 'brew install gh (https://cli.github.com), then gh auth login\n' ;;
    gh-axi) printf 'npm i -g gh-axi\n' ;;
    git) printf 'brew install git, or the Xcode command line tools\n' ;;
    tasks-axi) printf 'npm i -g tasks-axi\n' ;;
    no-mistakes) printf 'install from https://github.com/kunchenguid/no-mistakes (see its README)\n' ;;
    lavish-axi) printf 'npm i -g lavish-axi\n' ;;
    chrome-devtools-axi) printf 'npm i -g chrome-devtools-axi\n' ;;
    quota-axi) printf 'npm i -g quota-axi\n' ;;
    shellcheck) printf 'brew install shellcheck; on Linux x86_64, bin/cs-install-shellcheck.sh <dir> installs the pinned build\n' ;;
    python3) printf 'brew install python, or any python3 already on the system\n' ;;
    *) printf 'no recorded install suggestion\n'; return 1 ;;
  esac
}

# cs_deps_version <tool> - the installed version, or nothing when the tool is
# absent or reports no version. Exits nonzero when the tool is not on PATH.
cs_deps_version() {
  local tool=${1:-} raw
  [ -n "$tool" ] || return 1
  command -v "$tool" >/dev/null 2>&1 || return 1
  case "$tool" in
    # ShellCheck prints a banner first; its version is on a "version:" line.
    shellcheck) raw=$(shellcheck --version 2>/dev/null | awk '/^version:/ { print $2; exit }') ;;
    *) raw=$("$tool" --version 2>/dev/null | head -1) ;;
  esac
  # First dotted-number token: "jq-1.8.2" -> 1.8.2, "gh version 2.96.0 (...)" -> 2.96.0.
  printf '%s\n' "$raw" | grep -Eo '[0-9]+(\.[0-9]+)+' | head -1
}

# cs_deps_version_at_least <tool> <floor> - exit 0 when the installed version is
# at or above <floor>, comparing dotted numeric fields. Exits nonzero when the
# tool is absent, --version fails, or its complete output is not a clean dotted
# release number, so an unparseable or prerelease build reads as below-floor
# rather than silently passing. Floor values are owned by the calling script
# (bin/cs-deps-lib.sh header lists the owners), never here.
cs_deps_version_at_least() {
  local tool=${1:-} floor=${2:-} have
  [ -n "$tool" ] && [ -n "$floor" ] || return 1
  command -v "$tool" >/dev/null 2>&1 || return 1
  have=$("$tool" --version 2>/dev/null) || return 1
  [[ "$have" =~ ^[0-9]+(\.[0-9]+)+$ ]] || return 1
  [[ "$floor" =~ ^[0-9]+(\.[0-9]+)+$ ]] || return 1
  awk -v have="$have" -v floor="$floor" 'BEGIN {
    n = split(have, H, "."); m = split(floor, F, ".")
    len = (n > m ? n : m)
    for (i = 1; i <= len; i++) {
      h = H[i] + 0; f = F[i] + 0
      if (h > f) exit 0
      if (h < f) exit 1
    }
    exit 0
  }'
}
