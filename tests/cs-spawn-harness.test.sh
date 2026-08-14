#!/usr/bin/env bash
# Behavior (portable): cs-spawn.sh resolves and persists the root harness, and
# builds the harness-correct launch. A codex root stamps harness=codex and the
# codex notify launch (byte-compatible with before); a claude root stamps
# harness=claude, writes a per-soldier --settings file, and launches claude.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$ROOT/bin/cs-meta-lib.sh"

SPAWN="$ROOT/bin/cs-spawn.sh"
TMP=$(cs_test_tmproot cs-spawn-harness)
FAKEBIN=$(cs_fakebin "$TMP")
cs_git_identity

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "status --json") printf '%s\n' '{"server":{"protocol":16}}' ;;
  "worktree create")
    repo= branch=
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --cwd) repo=$2; shift ;;
        --branch) branch=$2; shift ;;
      esac
      shift
    done
    git -C "$repo" worktree add -q -b "$branch" "$CS_FAKE_SPAWN_WORKTREE"
    printf '{"result":{"workspace":{"workspace_id":"w1"},"root_pane":{"pane_id":"w1:p1"},"worktree":{"path":"%s","branch":"%s"}}}\n' "$CS_FAKE_SPAWN_WORKTREE" "$branch"
    ;;
  "pane run")
    # A headless scout still types its whole launch line into the pane's shell
    # (no composer/agent_status lifecycle for agent start to target), and an
    # interactive spawn types its env-export pre-step here. Capture to a
    # dedicated append-mode file when the caller provides one, so the later
    # `agent start` truncate of CS_FAKE_SPAWN_LAUNCH cannot clobber it.
    printf 'pane_run=%s\n' "${4:-}" >> "${CS_FAKE_SPAWN_PANE_RUN:-$CS_FAKE_SPAWN_LAUNCH}" ;;
  "agent start")
    # Every interactive soldier/capo launch now goes through native
    # `agent start <name> --kind <k> --pane <p> --timeout <ms> -- ARGV...`.
    # Capture the kind and the trailing argv (everything after --), which
    # reaches the launched binary literally with no shell evaluation.
    printf 'name=%s\n' "${3:-}" >> "${CS_FAKE_SPAWN_AGENT_START_CALLS:-/dev/null}"
    shift 2
    kind= pane= name=$1; shift
    argv=()
    in_argv=0
    while [ "$#" -gt 0 ]; do
      if [ "$in_argv" -eq 1 ]; then
        argv+=("$1")
      else
        case "$1" in
          --kind) kind=$2; shift ;;
          --pane) pane=$2; shift ;;
          --) in_argv=1 ;;
        esac
      fi
      shift
    done
    case "$name" in
      ''|[!a-z]*|*[!a-z0-9_-]*)
        printf '%s\n' '{"error":{"code":"invalid_agent_name","message":"agent name must start with a lowercase letter and contain only lowercase letters, digits, '-' or '_' (1-32 characters)"}}'
        exit 1
        ;;
    esac
    [ "${#name}" -le 32 ] || {
      printf '%s\n' '{"error":{"code":"invalid_agent_name","message":"agent name must start with a lowercase letter and contain only lowercase letters, digits, '-' or '_' (1-32 characters)"}}'
      exit 1
    }
    {
      printf 'name=%s\n' "$name"
      printf 'kind=%s\n' "$kind"
      printf 'pane=%s\n' "$pane"
      printf 'argv=%s\n' "${argv[*]}"
    } > "$CS_FAKE_SPAWN_LAUNCH"
    # cs-spawn now requires agent start itself to report interactive_ready,
    # instead of a separate hand-rolled agent-presence poll after `pane run`.
    # CS_FAKE_SPAWN_NO_AGENT=1 reproduces a launch agent start never confirms.
    if [ "${CS_FAKE_SPAWN_NO_AGENT:-0}" = 1 ]; then
      printf '{"error":{"code":"agent_not_ready","message":"timed out"}}\n'
      exit 1
    fi
    printf '{"result":{"agent":{"agent":"%s","agent_status":"idle","interactive_ready":true}}}\n' "$kind"
    ;;
  "pane wait-output")
    # The env-export pre-step's confirmation, always taken for a capo (its
    # CS_HOME/override-clearing prefix is unconditional).
    printf '{"result":{"matched":true}}\n' ;;
  "workspace list") printf '{"result":{"workspaces":[]}}\n' ;;
  "workspace create") printf '{"result":{"workspace":{"workspace_id":"wcapo"}}}\n' ;;
  "pane list") printf '{"result":{"panes":[{"pane_id":"wcapo:p1","workspace_id":"wcapo"}]}}\n' ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"w1:p1","cwd":"%s"}}}\n' "${CS_FAKE_SPAWN_WORKTREE:-}" ;;
  "pane read")
    # A generic empty-composer read (codex's glyph, which the classifier
    # recognizes regardless of which harness is actually running) so the
    # post-launch brief delivery (bin/cs-spawn.sh's _cs_spawn_deliver_brief,
    # which calls cs_herdr_agent_prompt_confirmed directly and bypasses
    # cs_prompt_guarded) proceeds on its first attempt instead of retrying
    # for its full window every spawn.
    printf '%s\n' $'\342\200\272 ' ;;
  "agent get") printf '{"result":{"agent":{"agent":"codex","agent_status":"idle"}}}\n' ;;
  "pane process-info")
    printf '{"result":{"process_info":{"shell_pid":10,"foreground_processes":[{"pid":20,"argv0":"codex"}]}}}\n' ;;
  "agent prompt")
    printf '%s' "${4:-}" > "${CS_FAKE_SPAWN_PROMPT:-/dev/null}"
    printf '{"result":{"type":"agent_prompted"}}\n' ;;
  *) printf '{}\n' ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"
printf -- '- project [local-only] - fixture\n' > "$HOME_DIR/config/projects.md"
REPO="$TMP/project"
cs_git_init_commit "$REPO"

# spawn_one drives BOTH ship and scout spawns, and a scout now refuses --mode /
# --yolo, so the ship posture flags are passed per call site rather than here.
spawn_one() {
  local harness=$1 id=$2 wt="$TMP/wt-$2"
  shift 2
  local arg prev='' brief_mode=''
  mkdir -p "$HOME_DIR/data/$id"
  printf 'implement the fixture\n' > "$HOME_DIR/data/$id/brief.md"
  # A ship fixture's brief must record the same delivery contract the spawn
  # passes; a scout's brief carries none. Without this the ship spawns would all
  # exercise the pre-contract compatibility warning instead of the cross-check.
  for arg in "$@"; do
    [ "$prev" = --mode ] && brief_mode=$arg
    prev=$arg
  done
  [ -n "$brief_mode" ] \
    && printf 'Delivery contract: mode=%s\n' "$brief_mode" >> "$HOME_DIR/data/$id/brief.md"
  # CS_CLAUDE_JSON sandboxes the folder-trust pre-seed away from the real
  # ~/.claude.json (claude spawns pre-trust their worktree). CLAUDE_CONFIG_DIR
  # is pinned empty so a developer's own credential-store split cannot add an
  # env pre-step these launch assertions do not expect.
  env PATH="$FAKEBIN:$PATH" CS_HARNESS_OVERRIDE="$harness" CLAUDE_CONFIG_DIR= \
    CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$HOME_DIR/state" \
    CS_CLAUDE_JSON="$TMP/claude.json" \
    CS_FAKE_SPAWN_WORKTREE="$wt" CS_FAKE_SPAWN_LAUNCH="$TMP/launch-$id" \
    CS_FAKE_SPAWN_PANE_RUN="$TMP/panerun-$id" \
    "$SPAWN" "$id" "$REPO" "$@" >/dev/null || fail "spawn ($harness) failed"
  # An interactive spawn is captured by `agent start`; a headless scout never
  # calls it and is captured by its `pane run` launch line instead. Returning
  # an empty string here would make every downstream assert_not_contains
  # vacuously true, so a spawn that captured nothing fails loudly.
  if [ -f "$TMP/launch-$id" ]; then
    cat "$TMP/launch-$id"
  elif [ -f "$TMP/panerun-$id" ]; then
    cat "$TMP/panerun-$id"
  else
    fail "spawn ($harness, $id) captured neither an agent start nor a pane run launch"
  fi
}

# --- codex root: unchanged launch shape, harness=codex ----------------------
launch=$(spawn_one codex t-codex --mode made --yolo off)
[ "$(cs_meta_get "$HOME_DIR/state/t-codex.meta" harness)" = codex ] || fail "codex meta harness"
assert_contains "$launch" "kind=codex" "codex root launches codex"
assert_contains "$launch" 'notify=' "codex root wires notify turn-end"
assert_not_contains "$launch" '--settings' "codex root does not use --settings"
assert_absent "$HOME_DIR/state/t-codex.claude-settings.json" "codex root writes no claude settings file"
pass "codex root: harness=codex, codex notify launch, no settings file"

launch=$(spawn_one codex Foo.Bar --mode made --yolo off)
assert_contains "$launch" "name=foo-bar-" "native agent names normalize task ids to Herdr's lowercase charset"
pass "a task id outside Herdr's agent-name charset reaches native agent start safely"

dot_launch=$launch
hyphen_launch=$(spawn_one codex Foo-Bar --mode made --yolo off)
dot_name=$(printf '%s\n' "$dot_launch" | sed -n 's/^name=//p')
hyphen_name=$(printf '%s\n' "$hyphen_launch" | sed -n 's/^name=//p')
[ "$dot_name" != "$hyphen_name" ] || fail "distinct accepted task ids must not collide as native agent names"
[ -f "$HOME_DIR/state/Foo.Bar.meta" ] || fail "dot task id was not preserved in its metadata path"
[ -f "$HOME_DIR/state/Foo-Bar.meta" ] || fail "hyphen task id was not preserved in its metadata path"
[ "$(cs_meta_get "$HOME_DIR/state/Foo.Bar.meta" kind)" = ship ] || fail "dot task metadata was not written"
[ "$(cs_meta_get "$HOME_DIR/state/Foo-Bar.meta" kind)" = ship ] || fail "hyphen task metadata was not written"
pass "distinct task ids receive distinct native names while task ids remain unchanged"

collision_a='a.a-A.a.a-a.a-a-A.A-a-a-a.a-A.A.A.a.a.A-'
collision_b='a-a-A.a-A-A-a-A.A-A-a-a.A.a.A-a.a.A.a-A-'
collision_a_launch=$(spawn_one codex "$collision_a" --mode made --yolo off)
collision_b_launch=$(spawn_one codex "$collision_b" --mode made --yolo off)
collision_a_name=$(printf '%s\n' "$collision_a_launch" | sed -n 's/^name=//p')
collision_b_name=$(printf '%s\n' "$collision_b_launch" | sed -n 's/^name=//p')
[ "$collision_a_name" != "$collision_b_name" ] \
  || fail "distinct accepted task ids must not collide under the native-name suffix"
pass "native names remain distinct beyond the 32-bit checksum collision domain"

cat > "$FAKEBIN/shasum" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$FAKEBIN/shasum"
fallback_launch=$(spawn_one codex Foo.Baz --mode made --yolo off)
fallback_name=$(printf '%s\n' "$fallback_launch" | sed -n 's/^name=//p')
[ "$fallback_name" != "foo-baz-" ] || fail "a failed shasum must not produce an empty native-name suffix"
rm -f "$FAKEBIN/shasum"
pass "a failed shasum falls through without emitting an empty native-name suffix"

cat > "$FAKEBIN/shasum" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cat > "$FAKEBIN/sha256sum" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$FAKEBIN/shasum" "$FAKEBIN/sha256sum"
no_digest_id=Foo.NoDigest
mkdir -p "$HOME_DIR/data/$no_digest_id"
printf 'implement the fixture\nDelivery contract: mode=made\n' > "$HOME_DIR/data/$no_digest_id/brief.md"
no_digest_calls="$TMP/no-digest-agent-start"
if output=$(env PATH="$FAKEBIN:$PATH" CS_HARNESS_OVERRIDE=codex \
  CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$HOME_DIR/state" \
  CS_CLAUDE_JSON="$TMP/claude.json" CS_FAKE_SPAWN_WORKTREE="$TMP/wt-no-digest" \
  CS_FAKE_SPAWN_LAUNCH="$TMP/launch-no-digest" CS_FAKE_SPAWN_AGENT_START_CALLS="$no_digest_calls" \
  "$SPAWN" "$no_digest_id" "$REPO" --mode made --yolo off 2>&1); then
  fail "spawn must fail closed when neither digest command yields a native name"
fi
assert_contains "$output" "shasum or sha256sum is required" "no valid digest has a named failure"
assert_absent "$no_digest_calls" "no native agent start is attempted without a valid digest"
rm -f "$FAKEBIN/shasum" "$FAKEBIN/sha256sum"
pass "native spawn fails closed without attempting agent start when both digest commands fail"

# --- capo spawn: unconditional env pre-step, no turn-end wiring --------------
# The old cs_harness_capo_launch unit test is gone with the function; this is
# its end-to-end replacement, exercising cs-spawn.sh's own capo argv
# construction (bin/cs-spawn.sh's capo branch) against a real launch.
CAPO_HOME="$TMP/capo-home"
mkdir -p "$CAPO_HOME"
: > "$CAPO_HOME/.cs-capo-home"
mkdir -p "$HOME_DIR/data/t-capo"
printf 'charter\n' > "$HOME_DIR/data/t-capo/brief.md"
env PATH="$FAKEBIN:$PATH" CS_HARNESS_OVERRIDE=claude CLAUDE_CONFIG_DIR="$TMP/work-claude" \
  CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$HOME_DIR/state" \
  CS_CLAUDE_JSON="$TMP/claude.json" CS_FAKE_SPAWN_LAUNCH="$TMP/launch-t-capo" \
  CS_FAKE_SPAWN_PROMPT="$TMP/prompt-t-capo" CS_FAKE_SPAWN_PANE_RUN="$TMP/panerun-t-capo" \
  "$SPAWN" t-capo "$CAPO_HOME" --capo >/dev/null || fail "capo spawn failed"
launch=$(cat "$TMP/launch-t-capo")
[ "$(cs_meta_get "$HOME_DIR/state/t-capo.meta" kind)" = capo ] || fail "capo meta kind"
assert_contains "$launch" "kind=claude" "capo launches the root harness"
assert_not_contains "$launch" '--settings' "capo has no turn-end wiring"
assert_not_contains "$launch" 'notify=' "capo has no turn-end wiring"
assert_not_contains "$launch" 'CONSIGLIERE_OP' "the charter never rides agent start's argv"
# The env pre-step is what binds the capo to ITS OWN home: dropping CS_HOME (or
# the whole pre-step) leaves every capo writing into the ROOT session's
# state/data. One exact substring pins the content AND the order: credential
# store first, then the override clears, then the capo's own home.
CAPO_ABS=$(cd "$CAPO_HOME" && pwd -P)
assert_contains "$(cat "$TMP/panerun-t-capo")" \
  "export CLAUDE_CONFIG_DIR='$TMP/work-claude' CS_ROOT_OVERRIDE= CS_STATE_OVERRIDE= CS_DATA_OVERRIDE= CS_CONFIG_OVERRIDE= CS_PROJECTS_OVERRIDE= CS_HOME='$CAPO_ABS'" \
  "the capo env pre-step must export the credential store, the override clears, and its own home, in that order"
prompt=$(cat "$TMP/prompt-t-capo")
[ "$(printf '%s' "$prompt" | "$ROOT/bin/cs-operational-input.sh" kind)" = launch-brief ] \
  || fail "the capo charter prompt lacks the launch-brief kind"
[ "$(printf '%s' "$prompt" | "$ROOT/bin/cs-operational-input.sh" body)" = "$(cat "$HOME_DIR/data/t-capo/brief.md")" ] \
  || fail "the capo charter prompt lost the charter body"
pass "capo spawn: env pre-step confirmed with its content, no turn-end wiring, correct harness, charter delivered as a typed follow-up prompt"

# --- the harness owns model and reasoning level ------------------------------
# Consigliere selects neither, on either harness and for every task kind, so no
# launch may name a model or a reasoning level and no task may record one.
for spec in "codex t-noprofile-codex-ship --mode made --yolo off" \
  "codex t-noprofile-codex-scout --scout" \
  "claude t-noprofile-claude-ship --mode made --yolo off" \
  "claude t-noprofile-claude-scout --scout"; do
  # shellcheck disable=SC2086
  set -- $spec
  launch=$(spawn_one "$@")
  id=$2
  assert_not_contains "$launch" '--model' "$id launches with no model flag"
  assert_not_contains "$launch" 'model_reasoning_effort' "$id launches with no codex reasoning-effort flag"
  assert_not_contains "$launch" '--effort' "$id launches with no claude effort flag"
  assert_no_grep '^model=' "$HOME_DIR/state/$id.meta" "$id records no model"
  assert_no_grep '^effort=' "$HOME_DIR/state/$id.meta" "$id records no effort"
done
pass "a spawn launches on the harness's own model and reasoning level, and records neither"

# --- --model and --effort are gone, and their absence is LOUD ----------------
# Silently ignoring either would look like consigliere had honoured a choice it
# no longer makes, so both must fail the spawn as unknown flags before anything
# durable exists.
for flag in --model --effort; do
  id="t-refuse${flag}"
  mkdir -p "$HOME_DIR/data/$id"
  printf 'implement the fixture\nDelivery contract: mode=made\n' > "$HOME_DIR/data/$id/brief.md"
  if output=$(env PATH="$FAKEBIN:$PATH" CS_HARNESS_OVERRIDE=codex \
    CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$HOME_DIR/state" \
    CS_CLAUDE_JSON="$TMP/claude.json" \
    CS_FAKE_SPAWN_WORKTREE="$TMP/wt-refuse$flag" CS_FAKE_SPAWN_LAUNCH="$TMP/launch-refuse$flag" \
    "$SPAWN" "$id" "$REPO" --mode made --yolo off "$flag" high 2>&1); then
    fail "$flag must be refused, not silently ignored"
  fi
  assert_contains "$output" "unknown flag $flag" "$flag is refused by name"
  assert_absent "$HOME_DIR/state/$id.meta" "$flag writes no metadata"
done
pass "--model and --effort are refused as unknown flags"

# --- claude root: --settings launch, harness=claude, settings file written --
launch=$(spawn_one claude t-claude --mode made --yolo off)
[ "$(cs_meta_get "$HOME_DIR/state/t-claude.meta" harness)" = claude ] || fail "claude meta harness"
assert_contains "$launch" "kind=claude" "claude root launches claude"
assert_contains "$launch" "--dangerously-skip-permissions" "claude root autonomy flag"
assert_contains "$launch" "--settings" "claude root wires turn-end via --settings"
assert_not_contains "$launch" 'notify=' "claude root does not use codex notify"
SETTINGS="$HOME_DIR/state/t-claude.claude-settings.json"
assert_present "$SETTINGS" "claude root writes a per-soldier settings file"
assert_grep '"Stop"' "$SETTINGS" "claude settings registers a Stop hook"
assert_grep 't-claude.turn-ended' "$SETTINGS" "claude settings touches the turn-end signal"
assert_no_grep 'cs-turnend-guard' "$SETTINGS" "soldier settings must not run the root guard"
# The launch references the settings file by path.
assert_contains "$launch" "$SETTINGS" "claude launch references the settings file"
assert_absent "$TMP/panerun-t-claude" "no credential-store split means no env pre-step is typed into the pane"
pass "claude root: harness=claude, --settings launch, settings file written"

# --- a credential-store split reaches the pane before the agent starts -------
# The pane's shell is spawned by the herdr daemon and does NOT inherit
# consigliere's environment, so a soldier under a work/personal claude split
# comes up against the wrong store unless the export pre-step actually lands.
mkdir -p "$HOME_DIR/data/t-claude-env"
printf 'implement the fixture\nDelivery contract: mode=made\n' > "$HOME_DIR/data/t-claude-env/brief.md"
env PATH="$FAKEBIN:$PATH" CS_HARNESS_OVERRIDE=claude CLAUDE_CONFIG_DIR="$TMP/work-claude" \
  CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$HOME_DIR/state" \
  CS_CLAUDE_JSON="$TMP/claude.json" \
  CS_FAKE_SPAWN_WORKTREE="$TMP/wt-t-claude-env" CS_FAKE_SPAWN_LAUNCH="$TMP/launch-t-claude-env" \
  CS_FAKE_SPAWN_PANE_RUN="$TMP/panerun-t-claude-env" \
  "$SPAWN" t-claude-env "$REPO" --mode made --yolo off >/dev/null || fail "claude credential-split spawn failed"
assert_contains "$(cat "$TMP/panerun-t-claude-env")" "export CLAUDE_CONFIG_DIR='$TMP/work-claude'" \
  "a soldier under a credential-store split must export the store into the pane before agent start"
pass "a claude credential-store split is exported into the pane shell before the agent starts"

# --- config/permission-mode.conf reaches a real spawn ----------------------------
# End-to-end, not just the launch-string unit: proves the home's config dir
# resolves the same way for the harness lib as it does for cs-spawn itself.
printf 'claude auto\n' > "$HOME_DIR/config/permission-mode.conf"
launch=$(spawn_one claude t-claude-permmode --mode made --yolo off)
assert_contains "$launch" "--permission-mode auto" "configured permission mode reaches the spawn launch as a clean argv token"
assert_not_contains "$launch" '--dangerously-skip-permissions' "configured mode replaces the bypass flag"

printf 'claude plan\n' > "$HOME_DIR/config/permission-mode.conf"
mkdir -p "$HOME_DIR/data/t-permmode-invalid"
printf 'implement the fixture\n' > "$HOME_DIR/data/t-permmode-invalid/brief.md"
if output=$(env PATH="$FAKEBIN:$PATH" CS_HARNESS_OVERRIDE=claude \
  CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$HOME_DIR/state" \
  CS_CLAUDE_JSON="$TMP/claude.json" \
  CS_FAKE_SPAWN_WORKTREE="$TMP/wt-permmode-invalid" CS_FAKE_SPAWN_LAUNCH="$TMP/launch-permmode-invalid" \
  "$SPAWN" t-permmode-invalid "$REPO" --mode made --yolo off 2>&1); then
  fail "an unusable permission mode must reject spawn"
fi
assert_contains "$output" "not a usable claude launch permission mode" "unusable mode error is specific"
assert_absent "$HOME_DIR/state/t-permmode-invalid.meta" "unusable mode writes no metadata"
rm -f "$HOME_DIR/config/permission-mode.conf"
pass "config/permission-mode.conf selects the claude launch mode and blocks an unusable one"

# --- the swallowed launch ----------------------------------------------------
# `pane run` hands the launch line to the pane's SHELL and reports success
# whether or not the shell was ready to read it. A freshly created worktree pane
# often is not, and the line is then lost unrecoverably (the same hazard
# tests/cs-herdr-lib-live.test.sh works around by re-submitting an idempotent
# probe). Before this check, cs-spawn printed "spawned", consigliere recorded
# the task as under way, and the pane sat at a bare prompt until the stale timer
# eventually noticed: a soldier that reported success and never existed.
mkdir -p "$HOME_DIR/data/t-swallowed"
printf 'implement the fixture\nDelivery contract: mode=made\n' > "$HOME_DIR/data/t-swallowed/brief.md"
if output=$(env PATH="$FAKEBIN:$PATH" CS_HARNESS_OVERRIDE=codex \
  CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$HOME_DIR/state" \
  CS_FAKE_SPAWN_WORKTREE="$TMP/wt-swallowed" CS_FAKE_SPAWN_LAUNCH="$TMP/launch-swallowed" \
  CS_FAKE_SPAWN_NO_AGENT=1 CS_SPAWN_LAUNCH_WAIT_SECS=2 \
  "$SPAWN" t-swallowed "$REPO" --mode made --yolo off 2>&1); then
  fail "spawn must fail when no agent appears after the launch"
fi
assert_contains "$output" "no agent appeared" "the swallowed launch must be named, not silently reported as spawned"
assert_not_contains "$output" "spawned t-swallowed" "a swallowed launch must never print a spawn success line"
pass "a launch line the shell swallowed fails loudly instead of reporting a spawn"

# --- optional worker telemetry reaches (only) a real instrumented spawn ------
# The launch artefacts above are the uninstrumented shape, which is the point:
# telemetry is resolved at spawn time, so a soldier launched while telemetry is
# off must be byte identical to one launched before the instrumentation existed.
# docs/telemetry.md owns the contract; this proves it end to end from cs-spawn.
assert_not_contains "$(cat "$TMP/launch-t-codex")" 'cs-telemetry-emit.sh' \
  "telemetry off must add nothing to a codex soldier launch"
[ "$(jq -r '.hooks.Stop[0].hooks | length' "$HOME_DIR/state/t-claude.claude-settings.json")" = 1 ] ||
  fail "telemetry off must leave the claude soldier's Stop hook list at exactly the turn-end touch"
[ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$HOME_DIR/state/t-claude.claude-settings.json")" \
  = "touch '$HOME_DIR/state/t-claude.turn-ended'" ] ||
  fail "telemetry off must leave the claude soldier's single Stop hook command as the bare turn-end touch"

mkdir -p "$HOME_DIR/host"
printf 'enabled true\n' > "$HOME_DIR/host/telemetry.conf"
export CS_TELEMETRY_DISABLE=''

launch=$(spawn_one codex t-telemetry-codex --mode made --yolo off)
assert_contains "$launch" 'touch' "the codex notify command must still touch the turn-end signal"
assert_contains "$launch" 'cs-telemetry-emit.sh' "an enabled home instruments the codex worker turn end"
assert_contains "$launch" '--worker --task' "the worker emitter is called with its task identity"
assert_not_contains "$launch" '--stdin' "codex notify carries no piped payload, so the emitter must not read stdin"
case "$launch" in
  *"touch '$HOME_DIR/state/t-telemetry-codex.turn-ended'; "*) ;;
  *) fail "the turn-end touch must run first, joined by ';' so telemetry cannot gate it: $launch" ;;
esac

launch=$(spawn_one claude t-telemetry-claude --mode made --yolo off)
SETTINGS="$HOME_DIR/state/t-telemetry-claude.claude-settings.json"
assert_not_contains "$launch" 'cs-telemetry-emit.sh' \
  "a claude soldier is instrumented through its settings file, not its launch line"
jq -e . "$SETTINGS" >/dev/null || fail "an instrumented claude settings file must stay valid JSON"
[ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$SETTINGS")" \
  = "touch '$HOME_DIR/state/t-telemetry-claude.turn-ended'" ] ||
  fail "the turn-end touch must remain the first, separate claude Stop hook command"
[ "$(jq -r '.hooks.Stop[0].hooks | length' "$SETTINGS")" = 2 ] ||
  fail "telemetry must be a second hook command, never folded into the touch"
case "$(jq -r '.hooks.Stop[0].hooks[1].command' "$SETTINGS")" in
  *cs-telemetry-emit.sh*--stdin) ;;
  *) fail "claude feeds the Stop payload to every hook command, so the emitter must read it from stdin" ;;
esac

launch=$(spawn_one codex t-telemetry-headless --scout --headless)
assert_not_contains "$launch" 'cs-telemetry-emit.sh' \
  "a headless scout's turn end is process exit; its launch line stays uninstrumented"
assert_contains "$launch" 'encode launch-brief' \
  "a headless scout's launch line must stamp its brief as typed launch-brief operational input"

unset CS_TELEMETRY_DISABLE
rm -f "$HOME_DIR/host/telemetry.conf"
pass "worker turn-end telemetry is added only when the home enables it, never ahead of the turn-end touch"

pass "cs-spawn harness resolution and launch"
