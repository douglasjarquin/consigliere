#!/usr/bin/env bash
# Behavior (portable): cs-harness-lib.sh - the single owner of per-harness facts.
# Root detection precedence, launch-string construction per harness/role, effort
# validation, and the skill/resume/instruction/busy accessors.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/cs-harness-lib.sh
. "$ROOT/bin/cs-harness-lib.sh"

TMP=$(cs_test_tmproot cs-harness)

# --- root detection precedence ----------------------------------------------
# lib.sh exports CS_HARNESS_OVERRIDE=codex; each case controls the inputs it needs.

# Override wins over everything.
got=$(CS_HARNESS_OVERRIDE=claude CLAUDECODE=1 CS_CONFIG_OVERRIDE=/nonexistent cs_harness_detect_root)
[ "$got" = claude ] || fail "override must win (got $got)"
got=$(CS_HARNESS_OVERRIDE=codex CLAUDECODE=1 CS_CONFIG_OVERRIDE=/nonexistent cs_harness_detect_root)
[ "$got" = codex ] || fail "override codex must win over CLAUDECODE (got $got)"
pass "CS_HARNESS_OVERRIDE has highest precedence"

# config/harness file beats env, when override is absent. Use a subshell to
# scope the unset (a prefix var assignment on a function call works in bash, but
# `env` cannot run a shell function).
mkdir -p "$TMP/cfg"
printf 'claude\n' > "$TMP/cfg/harness"
got=$(unset CS_HARNESS_OVERRIDE CLAUDECODE; CS_CONFIG_OVERRIDE="$TMP/cfg" cs_harness_detect_root)
[ "$got" = claude ] || fail "config/harness must be read (got $got)"
printf '  codex \n' > "$TMP/cfg/harness"  # whitespace tolerated
got=$(unset CS_HARNESS_OVERRIDE; CLAUDECODE=1 CS_CONFIG_OVERRIDE="$TMP/cfg" cs_harness_detect_root)
[ "$got" = codex ] || fail "config/harness must beat CLAUDECODE (got $got)"
printf 'garbage\n' > "$TMP/cfg/harness"  # invalid value ignored
got=$(unset CS_HARNESS_OVERRIDE CLAUDECODE; CS_CONFIG_OVERRIDE="$TMP/cfg" cs_harness_detect_root)
[ "$got" = codex ] || fail "invalid config/harness must fall through to default (got $got)"
pass "config/harness beats env and ignores invalid values"

# CLAUDECODE env, then default codex.
got=$(unset CS_HARNESS_OVERRIDE; CLAUDECODE=1 CS_CONFIG_OVERRIDE="$TMP/empty" cs_harness_detect_root)
[ "$got" = claude ] || fail "CLAUDECODE=1 must resolve claude (got $got)"
got=$(unset CS_HARNESS_OVERRIDE CLAUDECODE; CS_CONFIG_OVERRIDE="$TMP/empty" cs_harness_detect_root)
[ "$got" = codex ] || fail "default must be codex (got $got)"
pass "CLAUDECODE env then default codex"

# --- valid / binary ---------------------------------------------------------
cs_harness_valid codex || fail "codex must be valid"
cs_harness_valid claude || fail "claude must be valid"
cs_harness_valid gpt && fail "unknown harness must be invalid" || true
[ "$(cs_harness_binary codex)" = codex ] || fail "codex binary"
[ "$(cs_harness_binary claude)" = claude ] || fail "claude binary"
pass "valid and binary"

# --- effort validation ------------------------------------------------------
for e in default low medium high xhigh max; do
  cs_harness_effort_valid codex "$e" || fail "codex must accept $e"
  cs_harness_effort_valid claude "$e" || fail "claude must accept $e"
done
cs_harness_effort_valid codex ultra || fail "codex must accept ultra"
cs_harness_effort_valid claude ultra && fail "claude must reject ultra" || true
cs_harness_effort_valid codex bogus && fail "codex must reject bogus" || true
pass "effort validation (codex accepts max and ultra, claude rejects ultra)"

# --- flags ------------------------------------------------------------------
# The autonomy flag reads config/permission-mode from the active home, so every
# assertion below is pinned to a config dir that does not exist. Without this a
# real home's permission-mode file would change the expected launch strings.
export CS_CONFIG_OVERRIDE="$TMP/no-such-config"

[ -z "$(cs_harness_model_flag codex default)" ] || fail "default model -> empty flag"
[ "$(cs_harness_model_flag codex gpt-5)" = "--model 'gpt-5' " ] || fail "codex model flag"
[ "$(cs_harness_model_flag claude sonnet)" = "--model 'sonnet' " ] || fail "claude model flag"
[ "$(cs_harness_effort_flag codex high)" = "-c 'model_reasoning_effort=\"high\"' " ] || fail "codex effort flag"
[ "$(cs_harness_effort_flag codex max)" = "-c 'model_reasoning_effort=\"max\"' " ] || fail "codex max effort flag"
[ "$(cs_harness_effort_flag codex ultra)" = "-c 'model_reasoning_effort=\"ultra\"' " ] || fail "codex ultra effort flag"
[ "$(cs_harness_effort_flag claude high)" = "--effort 'high' " ] || fail "claude effort flag"
[ "$(cs_harness_autonomy_flag codex)" = "--dangerously-bypass-approvals-and-sandbox" ] || fail "codex autonomy"
[ "$(cs_harness_autonomy_flag claude)" = "--dangerously-skip-permissions" ] || fail "claude autonomy"
pass "model/effort/autonomy flags per harness"

# --- config/permission-mode -------------------------------------------------
# A claude home whose org policy forbids bypassPermissions selects a narrower
# launch mode here; the flag replaces the bypass flag, never joins it.
PM=$TMP/pm
mkdir -p "$PM"
pm_flag() { CS_CONFIG_OVERRIDE="$PM" cs_harness_autonomy_flag "$1"; }
pm_write() { printf '%s\n' "$1" > "$PM/permission-mode"; }

[ -z "$(CS_CONFIG_OVERRIDE="$PM" cs_harness_permission_mode claude)" ] ||
  fail "absent permission-mode file -> empty"

for mode in auto acceptEdits bypassPermissions; do
  pm_write "claude $mode"
  [ "$(pm_flag claude)" = "--permission-mode '$mode'" ] ||
    fail "claude $mode must render --permission-mode '$mode'"
done

pm_write "claude auto"
[ "$(pm_flag codex)" = "--dangerously-bypass-approvals-and-sandbox" ] ||
  fail "a claude-only record must leave codex on its own flag"

printf '# comment\n\n   claude   auto   \n' > "$PM/permission-mode"
[ "$(pm_flag claude)" = "--permission-mode 'auto'" ] ||
  fail "comments, blank lines, and surrounding whitespace must be tolerated"
pass "config/permission-mode selects a narrower claude launch mode"

# Rejections. Every one must fail closed: a bad file stops the dispatch instead
# of silently launching a soldier with wider or unusable permissions.
for bad in "claude plan" "claude manual" "claude dontAsk" "claude bogus" \
           "codex never" "gemini auto" "claude" "claude auto extra"; do
  printf '%s\n' "$bad" > "$PM/permission-mode"
  if pm_flag claude 2>/dev/null; then
    fail "config/permission-mode must reject: $bad"
  fi
done
printf 'claude auto\nclaude acceptEdits\n' > "$PM/permission-mode"
if pm_flag claude 2>/dev/null; then
  fail "config/permission-mode must reject a duplicate claude record"
fi
pass "config/permission-mode fails closed on unusable, unknown, and duplicate records"

# --- launch strings ---------------------------------------------------------
# Pin the credential-store selector so launch assertions never depend on the
# environment the developer happens to be running under.
unset CLAUDE_CONFIG_DIR
op=$(cs_harness_shell_quote /root/bin/cs-operational-input.sh)
br=$(cs_harness_shell_quote /home/data/t/brief.md)
te=$(cs_harness_shell_quote /home/state/t.turn-ended)
st=$(cs_harness_shell_quote /home/state/t.status)
hm=$(cs_harness_shell_quote /home/capo)
se=$(cs_harness_shell_quote /home/state/t.claude-settings.json)

soldier_codex=$(cs_harness_soldier_launch codex gpt-5 high "$op" "$br" "$te" "")
assert_contains "$soldier_codex" "codex --model 'gpt-5' " "codex soldier names the binary and model"
assert_contains "$soldier_codex" "--dangerously-bypass-approvals-and-sandbox" "codex soldier autonomy"
assert_contains "$soldier_codex" 'notify=' "codex soldier wires turn-end via notify"
assert_contains "$soldier_codex" 'encode launch-brief' "codex soldier stamps launch-brief"
assert_not_contains "$soldier_codex" '--settings' "codex soldier does not use --settings"

soldier_claude=$(cs_harness_soldier_launch claude sonnet high "$op" "$br" "$te" "$se")
assert_contains "$soldier_claude" "claude --model 'sonnet' --effort 'high' " "claude soldier names binary/model/effort"
assert_contains "$soldier_claude" "--dangerously-skip-permissions" "claude soldier autonomy"
assert_contains "$soldier_claude" "--settings '/home/state/t.claude-settings.json'" "claude soldier wires turn-end via --settings"
assert_not_contains "$soldier_claude" 'notify=' "claude soldier does not use codex notify"
assert_contains "$soldier_claude" 'encode launch-brief' "claude soldier stamps launch-brief"

scout_codex=$(cs_harness_scout_launch codex default default "$op" "$br" "$st")
assert_contains "$scout_codex" 'codex exec ' "codex scout uses codex exec"
scout_claude=$(cs_harness_scout_launch claude default default "$op" "$br" "$st")
assert_contains "$scout_claude" 'claude -p ' "claude scout uses claude -p"
assert_contains "$scout_claude" 'done: headless scout finished' "scout appends terminal status"

capo_claude=$(cs_harness_capo_launch claude default default "$op" "$br" "$hm")
assert_contains "$capo_claude" "CS_HOME='/home/capo' claude " "capo prefixes CS_HOME and names the harness"
assert_not_contains "$capo_claude" '--settings' "capo has no turn-end wiring"
assert_not_contains "$capo_claude" 'notify=' "capo has no turn-end wiring"
pass "launch strings per harness and role"

# Every claude launch role honors config/permission-mode, and the configured mode
# REPLACES the bypass flag in each one.
printf 'claude auto\n' > "$PM/permission-mode"
for role in soldier scout capo; do
  case $role in
    soldier) line=$(CS_CONFIG_OVERRIDE="$PM" cs_harness_soldier_launch claude default default "$op" "$br" "$te" "$se") ;;
    scout) line=$(CS_CONFIG_OVERRIDE="$PM" cs_harness_scout_launch claude default default "$op" "$br" "$st") ;;
    capo) line=$(CS_CONFIG_OVERRIDE="$PM" cs_harness_capo_launch claude default default "$op" "$br" "$hm") ;;
  esac
  assert_contains "$line" "--permission-mode 'auto'" "claude $role honors config/permission-mode"
  assert_not_contains "$line" '--dangerously-skip-permissions' "claude $role drops the bypass flag"
done

# A malformed file stops every launch role rather than falling back to bypass.
printf 'claude plan\n' > "$PM/permission-mode"
for role in soldier scout capo; do
  case $role in
    soldier) CS_CONFIG_OVERRIDE="$PM" cs_harness_soldier_launch claude default default "$op" "$br" "$te" "$se" 2>/dev/null ;;
    scout) CS_CONFIG_OVERRIDE="$PM" cs_harness_scout_launch claude default default "$op" "$br" "$st" 2>/dev/null ;;
    capo) CS_CONFIG_OVERRIDE="$PM" cs_harness_capo_launch claude default default "$op" "$br" "$hm" 2>/dev/null ;;
  esac && fail "claude $role must refuse an unusable permission mode"
done
rm -f "$PM/permission-mode"
pass "configured permission mode reaches every claude launch role and fails closed"

# --- credential-store forwarding ---------------------------------------------
# A pane is created by the long-lived herdr daemon, which does NOT inherit the
# environment of the consigliere process that asked for it. Under a
# work-vs-personal claude subscription split, a bare `claude` in that pane reads
# the default ~/.claude store and comes up unauthenticated, blocking the agent
# before it can do any work. Every claude launch role must restate
# CLAUDE_CONFIG_DIR on the launch line itself.
build_launch() {  # <role> -> launch string for that role
  case $1 in
    soldier) cs_harness_soldier_launch claude default default "$op" "$br" "$te" "$se" ;;
    scout) cs_harness_scout_launch claude default default "$op" "$br" "$st" ;;
    capo) cs_harness_capo_launch claude default default "$op" "$br" "$hm" ;;
  esac
}

export CLAUDE_CONFIG_DIR=/work/config/.claude
for role in soldier scout capo; do
  line=$(build_launch "$role")
  assert_contains "$line" "CLAUDE_CONFIG_DIR='/work/config/.claude' " \
    "claude $role forwards the credential store onto the launch line"
  # The prefix must leave the line runnable, not just present in it.
  bash -n -c "$line" 2>/dev/null ||
    fail "claude $role launch line must stay parseable with the env prefix"
done
# The prefix precedes the binary in every role, including the capo line that
# already carries its own CS_HOME assignment.
assert_contains "$(build_launch capo)" \
  "CLAUDE_CONFIG_DIR='/work/config/.claude' CS_ROOT_OVERRIDE=" \
  "capo keeps the credential store ahead of its own home assignments"

# codex selects no credential store by environment here, so it gets no prefix
# even when the claude variable is set.
codex_line=$(cs_harness_soldier_launch codex default default "$op" "$br" "$te" "")
assert_not_contains "$codex_line" 'CLAUDE_CONFIG_DIR' "codex launch is unaffected"

# Unset is the single-store default and must add nothing.
unset CLAUDE_CONFIG_DIR
for role in soldier scout capo; do
  assert_not_contains "$(build_launch "$role")" 'CLAUDE_CONFIG_DIR' \
    "claude $role adds no prefix when the store is not overridden"
done
pass "claude launch roles forward the selected credential store"

# --- settings json ----------------------------------------------------------
# A soldier's Stop hook touches the turn-end signal ONLY - the analog of codex's
# notify. The exit-2 guard is a root/capo concern, never on a soldier.
json=$(cs_harness_claude_settings_json /home/state/t.turn-ended)
assert_contains "$json" '"Stop"' "settings json has a Stop hook"
assert_contains "$json" 'touch /home/state/t.turn-ended' "settings json touches turn-end"
assert_not_contains "$json" 'cs-turnend-guard' "soldier settings must not run the root guard"
pass "claude settings json shape (touch-only)"

# --- claude folder trust pre-seed -------------------------------------------
CJSON="$TMP/claude.json"
printf '{"projects":{"/existing":{"hasTrustDialogAccepted":true}}}\n' > "$CJSON"
CS_CLAUDE_JSON="$CJSON" cs_harness_claude_trust_dir "/tmp/wt-a" || fail "trust_dir failed"
# New entry trusted; existing entry preserved.
python3 - "$CJSON" <<'PY' || exit 1
import json,sys
d=json.load(open(sys.argv[1])); p=d["projects"]
assert p["/tmp/wt-a"]["hasTrustDialogAccepted"] is True, "new dir not trusted"
assert p["/tmp/wt-a"]["hasCompletedProjectOnboarding"] is True, "onboarding not set"
assert p["/existing"]["hasTrustDialogAccepted"] is True, "existing entry lost"
PY
CS_CLAUDE_JSON="$CJSON" cs_harness_claude_untrust_dir "/tmp/wt-a" || fail "untrust_dir failed"
python3 - "$CJSON" <<'PY' || exit 1
import json,sys
d=json.load(open(sys.argv[1])); p=d["projects"]
assert "/tmp/wt-a" not in p, "untrust did not remove entry"
assert "/existing" in p, "untrust dropped an unrelated entry"
PY
# Missing file: trust_dir creates it; untrust is a no-op.
CS_CLAUDE_JSON="$TMP/absent.json" cs_harness_claude_trust_dir "/tmp/wt-b" || fail "trust_dir must create a missing file"
[ -f "$TMP/absent.json" ] || fail "trust_dir did not create the config"
pass "claude folder-trust pre-seed and cleanup"

# --- accessors --------------------------------------------------------------
[ "$(cs_harness_skill_prefix codex)" = '$' ] || fail "codex skill prefix"
[ "$(cs_harness_skill_prefix claude)" = '/' ] || fail "claude skill prefix"
[ "$(cs_harness_skill_needs_settle codex)" = 1 ] || fail "codex needs settle"
[ "$(cs_harness_skill_needs_settle claude)" = 0 ] || fail "claude no settle"
[ "$(cs_harness_resume_cmd codex)" = 'resume --last' ] || fail "codex resume"
[ "$(cs_harness_resume_cmd claude)" = '--continue' ] || fail "claude resume"
[ "$(cs_harness_instruction_file codex)" = AGENTS.md ] || fail "codex instruction file"
[ "$(cs_harness_instruction_file claude)" = CLAUDE.md ] || fail "claude instruction file"
[ "$(cs_harness_busy_re codex)" = "$(cs_harness_busy_re claude)" ] || fail "busy signature shared"
pass "skill/resume/instruction/busy accessors"

pass "cs-harness-lib behavior"
