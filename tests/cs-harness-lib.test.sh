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
for e in low medium high xhigh; do
  cs_harness_effort_valid codex "$e" || fail "codex must accept $e"
  cs_harness_effort_valid claude "$e" || fail "claude must accept $e"
done
cs_harness_effort_valid codex max && fail "codex must reject max" || true
cs_harness_effort_valid claude max || fail "claude must accept max"
cs_harness_effort_valid codex bogus && fail "codex must reject bogus" || true
pass "effort validation (codex rejects max, claude accepts)"

# --- flags ------------------------------------------------------------------
[ -z "$(cs_harness_model_flag codex default)" ] || fail "default model -> empty flag"
[ "$(cs_harness_model_flag codex gpt-5)" = "--model 'gpt-5' " ] || fail "codex model flag"
[ "$(cs_harness_model_flag claude sonnet)" = "--model 'sonnet' " ] || fail "claude model flag"
[ "$(cs_harness_effort_flag codex high)" = "-c 'model_reasoning_effort=\"high\"' " ] || fail "codex effort flag"
[ "$(cs_harness_effort_flag claude high)" = "--effort 'high' " ] || fail "claude effort flag"
[ "$(cs_harness_autonomy_flag codex)" = "--dangerously-bypass-approvals-and-sandbox" ] || fail "codex autonomy"
[ "$(cs_harness_autonomy_flag claude)" = "--dangerously-skip-permissions" ] || fail "claude autonomy"
pass "model/effort/autonomy flags per harness"

# --- launch strings ---------------------------------------------------------
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
