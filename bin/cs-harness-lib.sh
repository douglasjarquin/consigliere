# shellcheck shell=bash
# cs-harness-lib.sh - the single owner of every per-harness fact.
#
# Consigliere drives soldiers on one of two harnesses: `codex` (the default,
# home/personal/business) and `claude` (Claude Code CLI, work). A root session
# spawns soldiers on its OWN harness; the resolved value is persisted per-soldier
# as `harness=` in state/<id>.meta and read back by the watcher/send/crew-state.
#
# This library is the ONLY place that knows how each harness launches, signals a
# turn end, reports busy, invokes a skill, resumes, and names its instruction
# file. Everything else asks these functions. The codex branch reproduces the
# exact strings that used to live inline in cs-spawn.sh, so a codex root sees
# byte-identical behavior; claude is purely additive.
#
# Usage: . bin/cs-harness-lib.sh
#
# Verified live 2026-07-24 (claude 2.1.218): `claude --settings <file>
# --dangerously-skip-permissions` honors a Stop hook with no trust prompt; a
# Stop hook exit 2 blocks the stop and forces a continuation; the Stop payload
# carries `stop_hook_active` (same loop-guard field codex uses).

CS_HARNESS_DEFAULT=codex

# cs_harness_shell_quote <s> - single-quote a value for safe shell embedding.
cs_harness_shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# cs_harness_valid <h> - true if <h> is a supported harness name.
cs_harness_valid() {
  case "${1:-}" in
    codex|claude) return 0 ;;
    *) return 1 ;;
  esac
}

# cs_harness_binary <h> - the executable name for harness <h>.
cs_harness_binary() {
  case "$1" in
    codex) printf 'codex\n' ;;
    claude) printf 'claude\n' ;;
    *) return 1 ;;
  esac
}

# cs_harness_detect_root - resolve the ROOT session's harness.
# Precedence: CS_HARNESS_OVERRIDE (test/escape seam) -> config/harness file ->
# CLAUDECODE=1 (a Claude Code session) -> CS_HARNESS_DEFAULT (codex).
# Config dir: CS_CONFIG_OVERRIDE, else <CS_HOME|CS_ROOT|PWD>/config.
cs_harness_detect_root() {
  local override config_dir file value
  override=${CS_HARNESS_OVERRIDE:-}
  if [ -n "$override" ]; then
    cs_harness_valid "$override" && { printf '%s\n' "$override"; return 0; }
  fi
  config_dir=${CS_CONFIG_OVERRIDE:-${CS_HOME:-${CS_ROOT:-$PWD}}/config}
  file="$config_dir/harness"
  if [ -f "$file" ]; then
    value=$(tr -d '[:space:]' < "$file" 2>/dev/null || true)
    cs_harness_valid "$value" && { printf '%s\n' "$value"; return 0; }
  fi
  if [ "${CLAUDECODE:-}" = 1 ]; then
    printf 'claude\n'
    return 0
  fi
  printf '%s\n' "$CS_HARNESS_DEFAULT"
}

# cs_harness_effort_valid <h> <effort> - true if <effort> is accepted by <h>.
# codex refuses max (not in the bundled catalog); claude accepts it.
cs_harness_effort_valid() {
  local h=$1 effort=$2
  case "$effort" in
    ''|default|low|medium|high|xhigh) return 0 ;;
    max) [ "$h" = claude ] && return 0 || return 1 ;;
    *) return 1 ;;
  esac
}

# cs_harness_model_flag <h> <model> - rendered --model flag (trailing space) or
# empty for an unset/default model. Both harnesses accept --model.
cs_harness_model_flag() {
  local model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  printf -- '--model %s ' "$(cs_harness_shell_quote "$model")"
}

# cs_harness_effort_flag <h> <effort> - rendered effort flag (trailing space) or
# empty. codex uses `-c model_reasoning_effort="E"`; claude uses `--effort E`.
cs_harness_effort_flag() {
  local h=$1 effort=$2
  [ -n "$effort" ] && [ "$effort" != default ] || return 0
  case "$h" in
    codex) printf -- '-c %s ' "$(cs_harness_shell_quote "model_reasoning_effort=\"$effort\"")" ;;
    claude) printf -- '--effort %s ' "$(cs_harness_shell_quote "$effort")" ;;
    *) return 1 ;;
  esac
}

# cs_harness_autonomy_flag <h> - the unattended full-autonomy flag.
cs_harness_autonomy_flag() {
  case "$1" in
    codex) printf -- '--dangerously-bypass-approvals-and-sandbox' ;;
    claude) printf -- '--dangerously-skip-permissions' ;;
    *) return 1 ;;
  esac
}

# cs_harness_claude_settings_json <turnend> - the launch-scoped settings JSON for
# a claude soldier. Its Stop hook touches the turn-end signal every turn - the
# exact analog of the codex soldier's `-c notify=[touch turnend]`, and NOTHING
# more. The exit-2 continuation guard is a ROOT/capo concern (registered by the
# tracked `.codex/hooks.json` / `.claude/settings.json`, self-gated to the
# consigliere tree); a child soldier worktree is exempt from it, on both
# harnesses. cs-spawn writes this to a per-soldier file and passes it via
# `--settings <file>` so nothing lands in the boss's project tree (claude
# resolves a repo `.claude/settings.json` to the main checkout, not the worktree).
cs_harness_claude_settings_json() {
  local turnend=$1
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch %s"}]}]}}\n' \
    "$turnend"
}

# cs_harness_claude_json_path - the file claude persists per-folder trust in.
# Honors CS_CLAUDE_JSON (test/escape seam), then CLAUDE_CONFIG_DIR, then ~.
cs_harness_claude_json_path() {
  if [ -n "${CS_CLAUDE_JSON:-}" ]; then
    printf '%s\n' "$CS_CLAUDE_JSON"
  elif [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    printf '%s/.claude.json\n' "$CLAUDE_CONFIG_DIR"
  else
    printf '%s/.claude.json\n' "$HOME"
  fi
}

# cs_harness_claude_trust_dir <abs-dir> - mark a directory trusted in claude's
# config so an interactive claude launched there does not block at the
# folder-trust dialog. --dangerously-skip-permissions does NOT bypass that dialog
# in a TTY (only -p does; verified claude 2.1.218, 2026-07-24), and a soldier
# runs interactive in a herdr pane, so every fresh worktree would otherwise hang.
# Atomic read-modify-write under a bounded mkdir lock so concurrent spawns are
# safe; never drops the boss's other project entries.
cs_harness_claude_trust_dir() {
  local dir=$1 file lock attempt=0
  [ -n "$dir" ] || return 1
  command -v python3 >/dev/null 2>&1 || {
    printf 'cs-harness: python3 required to pre-trust a claude worktree\n' >&2
    return 1
  }
  file=$(cs_harness_claude_json_path)
  lock="$file.cslock"
  while ! mkdir "$lock" 2>/dev/null; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 50 ] || { printf 'cs-harness: timed out locking %s\n' "$file" >&2; return 1; }
    sleep 0.1
  done
  # shellcheck disable=SC2064
  trap "rmdir '$lock' 2>/dev/null || true" RETURN
  python3 - "$file" "$dir" <<'PY'
import json, os, sys
path, wt = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
except (FileNotFoundError, ValueError):
    doc = {}
if not isinstance(doc, dict):
    doc = {}
projects = doc.setdefault("projects", {})
entry = projects.get(wt)
if not isinstance(entry, dict):
    entry = {}
entry["hasTrustDialogAccepted"] = True
entry["hasCompletedProjectOnboarding"] = True
projects[wt] = entry
tmp = path + ".cstmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
os.replace(tmp, path)
PY
}

# cs_harness_claude_untrust_dir <abs-dir> - remove a directory's trust entry
# (used by teardown so torn-down soldier worktrees do not accumulate in the
# boss's claude config). Missing file or entry is a no-op success.
cs_harness_claude_untrust_dir() {
  local dir=$1 file lock attempt=0
  [ -n "$dir" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  file=$(cs_harness_claude_json_path)
  [ -f "$file" ] || return 0
  lock="$file.cslock"
  while ! mkdir "$lock" 2>/dev/null; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 50 ] || return 0
    sleep 0.1
  done
  # shellcheck disable=SC2064
  trap "rmdir '$lock' 2>/dev/null || true" RETURN
  python3 - "$file" "$dir" <<'PY'
import json, os, sys
path, wt = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
except (FileNotFoundError, ValueError):
    sys.exit(0)
if isinstance(doc, dict) and isinstance(doc.get("projects"), dict):
    doc["projects"].pop(wt, None)
    tmp = path + ".cstmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(doc, fh)
    os.replace(tmp, path)
PY
}

# cs_harness_soldier_launch <h> <model> <effort> <sq_op> <sq_brief> <sq_turnend> <sq_settings>
# Full launch string for an interactive supervised soldier (or interactive scout).
# codex wires turn-end inline via `-c notify=`; claude via the --settings Stop hook.
cs_harness_soldier_launch() {
  local h=$1 model=$2 effort=$3 sq_op=$4 sq_brief=$5 sq_turnend=$6 sq_settings=$7
  local mf ef auto
  mf=$(cs_harness_model_flag "$h" "$model")
  ef=$(cs_harness_effort_flag "$h" "$effort")
  auto=$(cs_harness_autonomy_flag "$h")
  # The launch STRING is data run later in the pane; its $(...), $?, and \" are
  # literal and must not expand here. SC2016 disabled deliberately.
  case "$h" in
    codex)
      # shellcheck disable=SC2016
      printf 'codex %s%s%s -c "notify=[\\"bash\\",\\"-c\\",\\"touch %s\\"]" "$(%s encode launch-brief < %s)"' \
        "$mf" "$ef" "$auto" "$sq_turnend" "$sq_op" "$sq_brief"
      ;;
    claude)
      # shellcheck disable=SC2016
      printf 'claude %s%s%s --settings %s "$(%s encode launch-brief < %s)"' \
        "$mf" "$ef" "$auto" "$sq_settings" "$sq_op" "$sq_brief"
      ;;
    *) return 1 ;;
  esac
}

# cs_harness_scout_launch <h> <model> <effort> <sq_op> <sq_brief> <sq_status>
# Fire-and-forget headless scout: process exit IS the turn end; the launch line
# appends the terminal done/failed status event.
cs_harness_scout_launch() {
  local h=$1 model=$2 effort=$3 sq_op=$4 sq_brief=$5 sq_status=$6
  local mf ef auto bin
  mf=$(cs_harness_model_flag "$h" "$model")
  ef=$(cs_harness_effort_flag "$h" "$effort")
  auto=$(cs_harness_autonomy_flag "$h")
  case "$h" in
    codex) bin='codex exec' ;;
    claude) bin='claude -p' ;;
    *) return 1 ;;
  esac
  # shellcheck disable=SC2016
  printf 'if %s %s%s%s "$(%s encode launch-brief < %s)"; then echo '\''done: headless scout finished; read the report'\'' >> %s; else echo "failed: %s exited $?" >> %s; fi' \
    "$bin" "$mf" "$ef" "$auto" "$sq_op" "$sq_brief" "$sq_status" "$bin" "$sq_status"
}

# cs_harness_capo_launch <h> <model> <effort> <sq_op> <sq_brief> <sq_home>
# A capo is a supervisor, not a supervised turn-taker: no turn-end wiring.
cs_harness_capo_launch() {
  local h=$1 model=$2 effort=$3 sq_op=$4 sq_brief=$5 sq_home=$6
  local mf ef auto bin
  mf=$(cs_harness_model_flag "$h" "$model")
  ef=$(cs_harness_effort_flag "$h" "$effort")
  auto=$(cs_harness_autonomy_flag "$h")
  bin=$(cs_harness_binary "$h")
  # shellcheck disable=SC2016
  printf 'CS_ROOT_OVERRIDE= CS_STATE_OVERRIDE= CS_DATA_OVERRIDE= CS_HOME=%s %s %s%s%s "$(%s encode launch-brief < %s)"' \
    "$sq_home" "$bin" "$mf" "$ef" "$auto" "$sq_op" "$sq_brief"
}

# cs_harness_busy_re <h> - the rendered-banner busy signature used ONLY to
# corroborate a native idle/unknown status (herdr-native working/blocked/done are
# trusted as-is). Both harnesses render "esc to interrupt" during a live turn.
cs_harness_busy_re() {
  case "$1" in
    codex|claude) printf '%s\n' '[Ee]sc to interrupt' ;;
    *) return 1 ;;
  esac
}

# cs_harness_skill_prefix <h> - how a skill is invoked in the composer.
cs_harness_skill_prefix() {
  case "$1" in
    codex) printf '$\n' ;;
    claude) printf '/\n' ;;
    *) return 1 ;;
  esac
}

# cs_harness_skill_needs_settle <h> - 1 if a $-skill send needs a pre-Enter
# settle (codex's completion popup swallows an atomic Enter); 0 otherwise.
cs_harness_skill_needs_settle() {
  case "$1" in
    codex) printf '1\n' ;;
    claude) printf '0\n' ;;
    *) return 1 ;;
  esac
}

# cs_harness_resume_cmd <h> - the cwd-keyed "resume this worktree's session" cmd.
cs_harness_resume_cmd() {
  case "$1" in
    codex) printf 'resume --last\n' ;;
    claude) printf -- '--continue\n' ;;
    *) return 1 ;;
  esac
}

# cs_harness_instruction_file <h> - the file the harness loads as project memory.
# Both resolve to the same content (cs-ensure-agents-md.sh keeps CLAUDE.md a
# symlink to AGENTS.md).
cs_harness_instruction_file() {
  case "$1" in
    codex) printf 'AGENTS.md\n' ;;
    claude) printf 'CLAUDE.md\n' ;;
    *) return 1 ;;
  esac
}
