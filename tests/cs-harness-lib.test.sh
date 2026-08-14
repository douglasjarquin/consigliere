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

UNSUPPORTED_PY_BIN="$TMP/unsupported-python-bin"
mkdir -p "$UNSUPPORTED_PY_BIN"
cat > "$UNSUPPORTED_PY_BIN/python3" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'Python 3.9.6\n'
  exit 0
fi
printf 'ModuleNotFoundError: No module named tomllib\n' >&2
exit 1
SH
chmod +x "$UNSUPPORTED_PY_BIN/python3"

UNSUPPORTED_CLAUDE_JSON="$TMP/unsupported-claude.json"
unsupported_claude_out=$(PATH="$UNSUPPORTED_PY_BIN:$PATH" \
  CS_CLAUDE_JSON="$UNSUPPORTED_CLAUDE_JSON" \
  cs_harness_claude_trust_dir /tmp/unsupported-claude 2>&1) &&
  fail 'claude trust must refuse unsupported Python'
assert_contains "$unsupported_claude_out" 'stdlib tomllib' \
  'claude trust names the missing tomllib capability'
[ ! -e "$UNSUPPORTED_CLAUDE_JSON" ] || fail 'claude trust mutated config before the Python preflight'

UNSUPPORTED_CODEX_TOML="$TMP/unsupported-home/.codex/config.toml"
unsupported_codex_out=$(PATH="$UNSUPPORTED_PY_BIN:$PATH" \
  CS_CODEX_TOML="$UNSUPPORTED_CODEX_TOML" \
  cs_harness_codex_trust_dir /tmp/unsupported-codex 2>&1) &&
  fail 'codex trust must refuse unsupported Python'
assert_contains "$unsupported_codex_out" 'stdlib tomllib' \
  'codex trust names the missing tomllib capability'
[ ! -e "$UNSUPPORTED_CODEX_TOML" ] || fail 'codex trust created config before the Python preflight'
[ ! -d "$TMP/unsupported-home" ] || fail 'codex trust created a config directory before the Python preflight'
pass 'unsupported Python fails closed before harness trust mutation'

LOW_VERSION_PY_BIN="$TMP/low-version-python-bin"
mkdir -p "$LOW_VERSION_PY_BIN"
cat > "$LOW_VERSION_PY_BIN/python3" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'Python 3.10.13\n'
  exit 0
fi
case "${3:-}" in
  *sys.version_info*)
    exit 1
    ;;
esac
exit 0
SH
chmod +x "$LOW_VERSION_PY_BIN/python3"

LOW_VERSION_CODEX_TOML="$TMP/low-version-home/.codex/config.toml"
low_version_codex_out=$(PATH="$LOW_VERSION_PY_BIN:$PATH" \
  CS_CODEX_TOML="$LOW_VERSION_CODEX_TOML" \
  cs_harness_codex_trust_dir /tmp/low-version-codex 2>&1) &&
  fail 'Python below the version floor must refuse codex trust even when tomllib appears importable'
assert_contains "$low_version_codex_out" 'Python 3.11+' \
  'below-floor Python trust failure names the version floor'
[ ! -e "$LOW_VERSION_CODEX_TOML" ] || fail 'below-floor Python trust created config before the version preflight'
[ ! -d "$TMP/low-version-home" ] || fail 'below-floor Python trust created a config directory before the version preflight'
pass 'below-floor Python fails closed before harness trust mutation'

SHADOW_TOMLLIB_DIR="$TMP/shadow-tomllib"
mkdir -p "$SHADOW_TOMLLIB_DIR"
cat > "$SHADOW_TOMLLIB_DIR/tomllib.py" <<'PY'
raise RuntimeError("operator-local tomllib shadow")
PY
SHADOW_CODEX_TOML="$TMP/shadow-home/.codex/config.toml"
PYTHONPATH="$SHADOW_TOMLLIB_DIR" CS_CODEX_TOML="$SHADOW_CODEX_TOML" \
  cs_harness_codex_trust_dir /tmp/shadowed-codex ||
  fail 'codex trust must use isolated Python imports'
[ -f "$SHADOW_CODEX_TOML" ] || fail 'isolated codex trust did not create config'
pass 'harness Python probes and TOML mutation ignore operator-local module shadowing'

# --- root detection precedence ----------------------------------------------
# lib.sh exports CS_HARNESS_OVERRIDE=codex; each case controls the inputs it needs.

# Override wins over everything.
got=$(CS_HARNESS_OVERRIDE=claude CLAUDECODE=1 CS_HOST_OVERRIDE=/nonexistent cs_harness_detect_root)
[ "$got" = claude ] || fail "override must win (got $got)"
got=$(CS_HARNESS_OVERRIDE=codex CLAUDECODE=1 CS_HOST_OVERRIDE=/nonexistent cs_harness_detect_root)
[ "$got" = codex ] || fail "override codex must win over CLAUDECODE (got $got)"
pass "CS_HARNESS_OVERRIDE has highest precedence"

# host/harness.conf file beats env, when override is absent. Use a subshell to
# scope the unset (a prefix var assignment on a function call works in bash, but
# `env` cannot run a shell function).
mkdir -p "$TMP/cfg"
printf 'claude\n' > "$TMP/cfg/harness.conf"
got=$(unset CS_HARNESS_OVERRIDE CLAUDECODE; CS_HOST_OVERRIDE="$TMP/cfg" cs_harness_detect_root)
[ "$got" = claude ] || fail "host/harness.conf must be read (got $got)"
printf '  codex \n' > "$TMP/cfg/harness.conf"  # whitespace tolerated
got=$(unset CS_HARNESS_OVERRIDE; CLAUDECODE=1 CS_HOST_OVERRIDE="$TMP/cfg" cs_harness_detect_root)
[ "$got" = codex ] || fail "host/harness.conf must beat CLAUDECODE (got $got)"
printf 'garbage\n' > "$TMP/cfg/harness.conf"  # invalid value ignored
got=$(unset CS_HARNESS_OVERRIDE CLAUDECODE; CS_HOST_OVERRIDE="$TMP/cfg" cs_harness_detect_root)
[ "$got" = codex ] || fail "invalid host/harness.conf must fall through to default (got $got)"
pass "host/harness.conf beats env and ignores invalid values"

# CLAUDECODE env, then default codex.
got=$(unset CS_HARNESS_OVERRIDE; CLAUDECODE=1 CS_HOST_OVERRIDE="$TMP/empty" cs_harness_detect_root)
[ "$got" = claude ] || fail "CLAUDECODE=1 must resolve claude (got $got)"
got=$(unset CS_HARNESS_OVERRIDE CLAUDECODE; CS_HOST_OVERRIDE="$TMP/empty" cs_harness_detect_root)
[ "$got" = codex ] || fail "default must be codex (got $got)"
pass "CLAUDECODE env then default codex"

# --- valid / binary ---------------------------------------------------------
cs_harness_valid codex || fail "codex must be valid"
cs_harness_valid claude || fail "claude must be valid"
cs_harness_valid gpt && fail "unknown harness must be invalid" || true
[ "$(cs_harness_binary codex)" = codex ] || fail "codex binary"
[ "$(cs_harness_binary claude)" = claude ] || fail "claude binary"
pass "valid and binary"

# --- flags ------------------------------------------------------------------
# The autonomy flag reads config/permission-mode.conf from the active home, so every
# assertion below is pinned to a config dir that does not exist. Without this a
# real home's permission-mode file would change the expected launch strings.
export CS_CONFIG_OVERRIDE="$TMP/no-such-config"
export CS_HOST_OVERRIDE="$TMP/no-such-host"

[ "$(cs_harness_autonomy_flag codex)" = "--dangerously-bypass-approvals-and-sandbox" ] || fail "codex autonomy"
[ "$(cs_harness_autonomy_flag claude)" = "--dangerously-skip-permissions" ] || fail "claude autonomy"
pass "the autonomy flag per harness"

# --- config/permission-mode.conf -------------------------------------------------
# A claude home whose org policy forbids bypassPermissions selects a narrower
# launch mode here; the flag replaces the bypass flag, never joins it.
PM=$TMP/pm
mkdir -p "$PM"
pm_flag() { CS_CONFIG_OVERRIDE="$PM" cs_harness_autonomy_flag "$1"; }
pm_write() { printf '%s\n' "$1" > "$PM/permission-mode.conf"; }

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

printf '# comment\n\n   claude   auto   \n' > "$PM/permission-mode.conf"
[ "$(pm_flag claude)" = "--permission-mode 'auto'" ] ||
  fail "comments, blank lines, and surrounding whitespace must be tolerated"
pass "config/permission-mode.conf selects a narrower claude launch mode"

# Rejections. Every one must fail closed: a bad file stops the dispatch instead
# of silently launching a soldier with wider or unusable permissions.
for bad in "claude plan" "claude manual" "claude dontAsk" "claude bogus" \
           "codex never" "gemini auto" "claude" "claude auto extra"; do
  printf '%s\n' "$bad" > "$PM/permission-mode.conf"
  if pm_flag claude 2>/dev/null; then
    fail "config/permission-mode.conf must reject: $bad"
  fi
done
printf 'claude auto\nclaude acceptEdits\n' > "$PM/permission-mode.conf"
if pm_flag claude 2>/dev/null; then
  fail "config/permission-mode.conf must reject a duplicate claude record"
fi
pass "config/permission-mode.conf fails closed on unusable, unknown, and duplicate records"

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

soldier_codex=$(cs_harness_soldier_launch codex "$op" "$br" "$te" "")
assert_contains "$soldier_codex" "codex --dangerously" "codex soldier names the binary, then its own flags"
assert_contains "$soldier_codex" "--dangerously-bypass-approvals-and-sandbox" "codex soldier autonomy"
assert_contains "$soldier_codex" 'notify=' "codex soldier wires turn-end via notify"
assert_contains "$soldier_codex" 'encode launch-brief' "codex soldier stamps launch-brief"
assert_not_contains "$soldier_codex" '--settings' "codex soldier does not use --settings"

soldier_claude=$(cs_harness_soldier_launch claude "$op" "$br" "$te" "$se")
assert_contains "$soldier_claude" "claude --dangerously" "claude soldier names the binary, then its own flags"
assert_contains "$soldier_claude" "--dangerously-skip-permissions" "claude soldier autonomy"
assert_contains "$soldier_claude" "--settings '/home/state/t.claude-settings.json'" "claude soldier wires turn-end via --settings"
assert_not_contains "$soldier_claude" 'notify=' "claude soldier does not use codex notify"
assert_contains "$soldier_claude" 'encode launch-brief' "claude soldier stamps launch-brief"

scout_codex=$(cs_harness_scout_launch codex "$op" "$br" "$st")
assert_contains "$scout_codex" 'codex exec ' "codex scout uses codex exec"
scout_claude=$(cs_harness_scout_launch claude "$op" "$br" "$st")
assert_contains "$scout_claude" 'claude -p ' "claude scout uses claude -p"
assert_contains "$scout_claude" 'done: headless scout finished' "scout appends terminal status"

# The relaunch shape: identical flags and turn-end wiring, the harness's own
# cwd-keyed resume command in place of the brief prompt.
resume_codex=$(cs_harness_soldier_resume codex "$te" "" "")
assert_contains "$resume_codex" "codex resume --last --dangerously" "codex resume names the subcommand, then the flags"
assert_contains "$resume_codex" "--dangerously-bypass-approvals-and-sandbox" "codex resume keeps autonomy"
assert_contains "$resume_codex" 'notify=' "codex resume keeps the turn-end wiring"
assert_not_contains "$resume_codex" 'encode launch-brief' "a resume carries no brief prompt"
resume_claude=$(cs_harness_soldier_resume claude "$te" "$se" "")
assert_contains "$resume_claude" "claude --continue --dangerously" "claude resume names the flag, then the flags"
assert_contains "$resume_claude" "--settings '/home/state/t.claude-settings.json'" "claude resume keeps the turn-end wiring"
assert_not_contains "$resume_claude" 'encode launch-brief' "a claude resume carries no brief prompt"

capo_claude=$(cs_harness_capo_launch claude "$op" "$br" "$hm")
assert_contains "$capo_claude" "CS_HOME='/home/capo' claude " "capo prefixes CS_HOME and names the harness"
assert_not_contains "$capo_claude" '--settings' "capo has no turn-end wiring"
assert_not_contains "$capo_claude" 'notify=' "capo has no turn-end wiring"
pass "launch strings per harness and role"

# Every claude launch role honors config/permission-mode.conf, and the configured mode
# REPLACES the bypass flag in each one.
printf 'claude auto\n' > "$PM/permission-mode.conf"
for role in soldier scout capo; do
  case $role in
    soldier) line=$(CS_CONFIG_OVERRIDE="$PM" cs_harness_soldier_launch claude "$op" "$br" "$te" "$se") ;;
    scout) line=$(CS_CONFIG_OVERRIDE="$PM" cs_harness_scout_launch claude "$op" "$br" "$st") ;;
    capo) line=$(CS_CONFIG_OVERRIDE="$PM" cs_harness_capo_launch claude "$op" "$br" "$hm") ;;
  esac
  assert_contains "$line" "--permission-mode 'auto'" "claude $role honors config/permission-mode.conf"
  assert_not_contains "$line" '--dangerously-skip-permissions' "claude $role drops the bypass flag"
done

# A malformed file stops every launch role rather than falling back to bypass.
printf 'claude plan\n' > "$PM/permission-mode.conf"
for role in soldier scout capo; do
  case $role in
    soldier) CS_CONFIG_OVERRIDE="$PM" cs_harness_soldier_launch claude "$op" "$br" "$te" "$se" 2>/dev/null ;;
    scout) CS_CONFIG_OVERRIDE="$PM" cs_harness_scout_launch claude "$op" "$br" "$st" 2>/dev/null ;;
    capo) CS_CONFIG_OVERRIDE="$PM" cs_harness_capo_launch claude "$op" "$br" "$hm" 2>/dev/null ;;
  esac && fail "claude $role must refuse an unusable permission mode"
done
rm -f "$PM/permission-mode.conf"
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
    soldier) cs_harness_soldier_launch claude "$op" "$br" "$te" "$se" ;;
    scout) cs_harness_scout_launch claude "$op" "$br" "$st" ;;
    capo) cs_harness_capo_launch claude "$op" "$br" "$hm" ;;
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
codex_line=$(cs_harness_soldier_launch codex "$op" "$br" "$te" "")
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

# --- codex folder trust pre-seed --------------------------------------------
# codex has the same dialog as claude and its bypass flag does not skip it either,
# so cs-spawn.sh pre-trusts a codex worktree too and cs-teardown.sh gives the entry
# back. Unlike claude's JSON store this is TOML, edited by append-and-block-remove,
# so the round trip must preserve unrelated tables exactly.
CTOML="$TMP/codex-config.toml"
printf '[tui]\ntheme = "dark"\n\n[projects."/existing"]\ntrust_level = "trusted"\n' > "$CTOML"
CS_CODEX_TOML="$CTOML" cs_harness_codex_trust_dir "/tmp/wt with space" || fail "codex trust_dir failed"
# Idempotent: a second call must not duplicate the table (a duplicate TOML table
# is a parse error, so this would corrupt the boss's config outright).
before_bytes=$(wc -c < "$CTOML")
CS_CODEX_TOML="$CTOML" cs_harness_codex_trust_dir "/tmp/wt with space" || fail "codex trust_dir not idempotent"
[ "$(wc -c < "$CTOML")" = "$before_bytes" ] || fail "codex trust_dir rewrote an already-trusted config"
python3 - "$CTOML" <<'PY' || exit 1
import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
p = d["projects"]
assert p["/tmp/wt with space"]["trust_level"] == "trusted", "new dir not trusted"
assert p["/existing"]["trust_level"] == "trusted", "existing entry lost"
assert d["tui"] == {"theme": "dark"}, "unrelated table changed"
PY
CS_CODEX_TOML="$CTOML" cs_harness_codex_untrust_dir "/tmp/wt with space" || fail "codex untrust_dir failed"
python3 - "$CTOML" <<'PY' || exit 1
import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
p = d["projects"]
assert "/tmp/wt with space" not in p, "untrust did not remove the entry"
assert "/existing" in p, "untrust dropped an unrelated entry"
assert d["tui"] == {"theme": "dark"}, "untrust changed an unrelated table"
PY
# A config that does not parse is the boss's to fix: refuse loudly rather than
# appending to it, and leave the bytes untouched.
printf 'this is [[[ not toml\n' > "$CTOML"
if CS_CODEX_TOML="$CTOML" cs_harness_codex_trust_dir "/tmp/wt-c" 2>/dev/null; then
  fail "codex trust_dir must refuse an unparseable config"
fi
[ "$(cat "$CTOML")" = 'this is [[[ not toml' ] || fail "codex trust_dir modified an unparseable config"
# untrust is cleanup: it must never fail teardown, even on that same bad file.
CS_CODEX_TOML="$CTOML" cs_harness_codex_untrust_dir "/tmp/wt-c" || fail "codex untrust_dir must no-op on a bad config"
# Missing file: trust creates it; untrust on a missing file is a no-op success.
CS_CODEX_TOML="$TMP/absent-codex.toml" cs_harness_codex_trust_dir "/tmp/wt-d" || fail "codex trust_dir must create a missing config"
python3 -c 'import sys,tomllib; assert "/tmp/wt-d" in tomllib.load(open(sys.argv[1],"rb"))["projects"]' "$TMP/absent-codex.toml" \
  || fail "created codex config lacks the trust entry"
CS_CODEX_TOML="$TMP/still-absent.toml" cs_harness_codex_untrust_dir "/tmp/wt-e" || fail "codex untrust_dir must no-op on a missing config"
# Missing DIRECTORY, not just missing file: the lock is a sibling of the config, so
# a home whose codex config dir does not exist yet must still be pre-trustable
# rather than aborting the spawn on a lock it could never take.
CS_CODEX_TOML="$TMP/fresh-home/.codex/config.toml" cs_harness_codex_trust_dir "/tmp/wt-f" \
  || fail "codex trust_dir must create a missing config directory"
python3 -c 'import sys,tomllib; assert "/tmp/wt-f" in tomllib.load(open(sys.argv[1],"rb"))["projects"]' \
  "$TMP/fresh-home/.codex/config.toml" || fail "config created in a fresh dir lacks the trust entry"
pass "codex folder-trust pre-seed and cleanup"

# --- the round trip is byte-identical ---------------------------------------
# A spawn/teardown pair runs once per task against the boss's real config, so
# "restores the entry" is not enough: anything the pair leaves behind accumulates
# forever. The trailing-newline case is the one that bit - trust appends a blank
# separator line, and an untrust that put one back at end of file grew the file by
# a line per torn-down worktree.
RT="$TMP/roundtrip.toml"
for tail_shape in 'trailing-table' 'trailing-newline'; do
  case "$tail_shape" in
    trailing-table)   printf '[tui]\ntheme = "dark"\n\n[projects."/keep"]\ntrust_level = "trusted"\n' > "$RT" ;;
    trailing-newline) printf '[tui]\ntheme = "dark"\n' > "$RT" ;;
  esac
  cp "$RT" "$RT.orig"
  CS_CODEX_TOML="$RT" cs_harness_codex_trust_dir "/tmp/wt-rt" || fail "$tail_shape: trust failed"
  cmp -s "$RT" "$RT.orig" && fail "$tail_shape: trust did not change the file"
  CS_CODEX_TOML="$RT" cs_harness_codex_untrust_dir "/tmp/wt-rt" || fail "$tail_shape: untrust failed"
  cmp -s "$RT" "$RT.orig" || fail "$tail_shape: the trust/untrust round trip must leave the config byte-identical"
done
# Mid-file removal keeps the blank line that separates the surviving tables, so a
# later table never ends up glued to the one before it.
printf '[tui]\ntheme = "dark"\n\n[projects."/keep"]\ntrust_level = "trusted"\n' > "$RT"
CS_CODEX_TOML="$RT" cs_harness_codex_trust_dir "/tmp/wt-mid" || fail "mid-file: trust failed"
printf '\n[extra]\nk = 1\n' >> "$RT"
CS_CODEX_TOML="$RT" cs_harness_codex_untrust_dir "/tmp/wt-mid" || fail "mid-file: untrust failed"
python3 - "$RT" <<'PY' || exit 1
import sys, tomllib
raw = open(sys.argv[1], encoding="utf-8").read()
d = tomllib.loads(raw)
assert "/tmp/wt-mid" not in d["projects"], "mid-file untrust left the entry"
assert d["extra"] == {"k": 1}, "mid-file untrust damaged the table after it"
assert '[projects."/keep"]' in raw, "mid-file untrust dropped the surviving projects table"
assert "\n\n[extra]\n" in raw, f"the surviving tables lost their blank separator:\n{raw}"
PY
pass "codex trust round trip is byte-identical and keeps table separation"

# --- the trust store resolves to the store codex itself reads ----------------
# CODEX_HOME is deliberately NOT isolated for a soldier (it holds auth.json), so
# the only two overrides are the test seam and an explicitly chosen CODEX_HOME.
[ "$(CS_CODEX_TOML=/x/y.toml cs_harness_codex_config_path)" = /x/y.toml ] \
  || fail "the test seam must win"
[ "$(CS_CODEX_TOML='' CODEX_HOME=/c/home cs_harness_codex_config_path)" = /c/home/config.toml ] \
  || fail "CODEX_HOME must select its own config.toml"
[ "$(CS_CODEX_TOML='' CODEX_HOME='' HOME=/h cs_harness_codex_config_path)" = /h/.codex/config.toml ] \
  || fail "the default store is ~/.codex/config.toml"
pass "codex trust store path resolution"

# --- accessors --------------------------------------------------------------
[ "$(cs_harness_skill_prefix codex)" = '$' ] || fail "codex skill prefix"
[ "$(cs_harness_skill_prefix claude)" = '/' ] || fail "claude skill prefix"
[ "$(cs_harness_composer_command_settle codex)" = 1 ] || fail "codex needs settle"
[ "$(cs_harness_composer_command_settle claude)" = 0 ] || fail "claude no settle"
[ "$(cs_harness_resume_cmd codex)" = 'resume --last' ] || fail "codex resume"
[ "$(cs_harness_resume_cmd claude)" = '--continue' ] || fail "claude resume"
# Lifecycle mechanics: one key for both harnesses, one exit command each, and
# herdr's canonical key spelling (docs/herdr.md refuses anything else).
[ "$(cs_harness_interrupt_key codex)" = esc ] || fail "codex interrupt key"
[ "$(cs_harness_interrupt_key claude)" = esc ] || fail "claude interrupt key"
[ "$(cs_harness_exit_command codex)" = '/quit' ] || fail "codex exit command"
[ "$(cs_harness_exit_command claude)" = '/exit' ] || fail "claude exit command"
for fn in cs_harness_interrupt_key cs_harness_exit_command cs_harness_composer_command_settle; do
  "$fn" bogus >/dev/null 2>&1 && fail "$fn must refuse an unknown harness"
done
[ "$(cs_harness_instruction_file codex)" = AGENTS.md ] || fail "codex instruction file"
[ "$(cs_harness_instruction_file claude)" = CLAUDE.md ] || fail "claude instruction file"
[ "$(cs_harness_busy_re codex)" = "$(cs_harness_busy_re claude)" ] || fail "busy signature shared"
# Live-verified 2026-08-11 (codex-cli 0.147.0, claude 2.1.228): the bare skill
# name activates on both harnesses (.no-mistakes/evidence/task-1-*.txt).
[ "$(cs_harness_plan_skill codex)" = 'ulw-plan' ] || fail "codex plan skill"
[ "$(cs_harness_plan_skill claude)" = 'omo:planing-prometheustic' ] || fail "claude plan skill"
[ "$(cs_harness_start_work_skill codex)" = 'start-work' ] || fail "codex start-work skill"
[ "$(cs_harness_start_work_skill claude)" = 'omo:start-work' ] || fail "claude start-work skill"
for fn in cs_harness_plan_skill cs_harness_start_work_skill; do
  "$fn" bogus >/dev/null 2>&1 && fail "$fn must refuse an unknown harness"
done
pass "skill/resume/instruction/busy accessors"

# --- omo install detection ---------------------------------------------------
# Isolated from the developer's own real ~/.codex and ~/.claude: both env
# overrides point at fixture dirs under $TMP, never the real installs.
OMO_CODEX="$TMP/codex-home"
OMO_CLAUDE="$TMP/claude-home"
mkdir -p "$OMO_CODEX/plugins/cache/sisyphuslabs/omo" "$OMO_CLAUDE/plugins/cache/sisyphuslabs/omo"

CODEX_HOME="$OMO_CODEX" cs_harness_omo_installed codex || fail "codex omo present must report installed"
CLAUDE_CONFIG_DIR="$OMO_CLAUDE" cs_harness_omo_installed claude || fail "claude omo present must report installed"
CODEX_HOME="$TMP/no-such-codex" cs_harness_omo_installed codex && fail "codex omo absent must report not installed"
CLAUDE_CONFIG_DIR="$TMP/no-such-claude" cs_harness_omo_installed claude && fail "claude omo absent must report not installed"
cs_harness_omo_installed bogus && fail "cs_harness_omo_installed must refuse an unknown harness"
pass "cs_harness_omo_installed detects the real plugin cache dir per harness, isolated from the developer's own installs"

pass "cs-harness-lib behavior"
