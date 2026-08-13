#!/usr/bin/env bash
# Regression coverage for the canonical operational-input wire, legacy marker
# bytes, classifier integration, and each machine-input boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OP="$ROOT/bin/cs-operational-input.sh"
CLASSIFY="$ROOT/bin/cs-classify-lib.sh"
SESSION_START="$ROOT/bin/cs-session-start.sh"
TURNEND_GUARD="$ROOT/bin/cs-turnend-guard.sh"
SPAWN="$ROOT/bin/cs-spawn.sh"
TMP=$(cs_test_tmproot cs-operational-input)

# shellcheck source=bin/cs-operational-input.sh
. "$OP"

test_library_and_cli_round_trip() {
  local sourced kind body encoded out rc
  sourced=$(bash -uec '. "$1"' _ "$OP") || fail "library is not set -e/-u source-safe"
  [ -z "$sourced" ] || fail "sourcing operational-input emitted output"
  assert_contains "$("$OP" --help)" "encode <kind>" "--help omits encode"

  body=$'first line\nsecond: line'
  for kind in launch-brief session-start watcher turn-end-guard away-supervisor from-consigliere; do
    encoded=$(printf '%s' "$body" | "$OP" encode "$kind") || fail "encode failed for $kind"
    [ "$(printf '%s' "$encoded" | "$OP" kind)" = "$kind" ] || fail "kind round-trip failed for $kind"
    [ "$(printf '%s' "$encoded" | "$OP" classify)" = "$kind" ] || fail "classify round-trip failed for $kind"
    [ "$(printf '%s' "$encoded" | "$OP" body)" = "$body" ] || fail "body round-trip failed for $kind"
  done

  [ "$(printf 'boss wording can mention watcher and launch brief' | "$OP" classify)" = boss ] \
    || fail "unmarked boss input was not classified boss"

  out=$(printf 'not encoded' | "$OP" kind 2>&1)
  rc=$?
  expect_code 1 "$rc" "kind non-match"
  [ -z "$out" ] || fail "kind non-match emitted diagnostics"
  out=$(printf 'body' | "$OP" encode unknown 2>&1)
  rc=$?
  expect_code 2 "$rc" "encode misuse"
  [ -z "$out" ] || fail "encode misuse emitted diagnostics"
  pass "operational-input library and CLI are source-safe and round-trip every kind"
}

test_exact_compatibility_bytes() {
  local separator expected_from got
  separator=$(printf '\342\201\243')
  expected_from="[cs-from-consigliere]${separator}"
  [ "$CS_INJECT_MARK" = "$separator" ] || fail "bare away marker bytes changed"
  [ "$CS_FROMCONS_MARK" = "$expected_from" ] || fail "from-consigliere marker bytes changed"
  cs_operational_input_construct from-consigliere "route this" got
  [ "$got" = "${expected_from}route this" ] || fail "from-consigliere construction changed bytes"
  pass "bare away and labeled from-consigliere marker bytes remain exact"
}

test_classifier_types_and_boss_passthrough() {
  local encoded
  # shellcheck source=bin/cs-classify-lib.sh
  . "$CLASSIFY"
  cs_operational_input_construct turn-end-guard "continue supervision" encoded
  [ "$(cs_classify_input "$encoded")" = turn-end-guard ] || fail "shared classifier lost typed kind"
  [ "$(cs_classify_input "continue supervision")" = boss ] || fail "shared classifier did not pass boss text through"
  cs_input_is_boss "plain boss text" || fail "boss predicate rejected unmarked text"
  cs_input_is_boss "$encoded" && fail "boss predicate accepted operational input"
  pass "shared classifier returns structural kinds and preserves unmarked boss input"
}

test_session_start_stamping() {
  local home out kind body
  home="$TMP/session-home"
  mkdir -p "$home/data" "$home/state" "$home/config"
  out=$(env CS_HOME="$home" CS_DATA_OVERRIDE="$home/data" \
    CS_STATE_OVERRIDE="$home/state" CS_CONFIG_OVERRIDE="$home/config" \
    "$SESSION_START") || fail "session-start fixture failed"
  kind=$(printf '%s' "$out" | "$OP" kind) || fail "session-start output is not typed"
  [ "$kind" = session-start ] || fail "session-start output kind is $kind"
  body=$(printf '%s' "$out" | "$OP" body) || fail "session-start body did not decode"
  assert_contains "$body" "SESSION START - $home" "session-start body lost its digest"
  pass "session-start digest carries the session-start kind"
}

test_turnend_guard_stamping() {
  local root state out rc kind body
  root="$TMP/guard-root"
  state="$root/state"
  mkdir -p "$root/bin" "$state"
  printf '# fixture\n' > "$root/AGENTS.md"
  git -C "$root" init -q
  printf 'pane=w1:p1\nkind=ship\n' > "$state/task.meta"
  out=$(printf '{"stop_hook_active":false}' | env CS_ROOT_OVERRIDE="$root" \
    CS_STATE_OVERRIDE="$state" CS_GUARD_GRACE=0 "$TURNEND_GUARD" 2>&1)
  rc=$?
  expect_code 2 "$rc" "turn-end guard with unsupervised work"
  kind=$(printf '%s' "$out" | "$OP" kind) || fail "turn-end guard output is not typed"
  [ "$kind" = turn-end-guard ] || fail "turn-end guard output kind is $kind"
  body=$(printf '%s' "$out" | "$OP" body) || fail "turn-end guard body did not decode"
  assert_contains "$body" "THIS HOME CANNOT WAKE ITSELF" "turn-end guard lost its continuation body"
  pass "turn-end Stop-hook continuation carries the turn-end-guard kind"
}

test_spawn_launch_brief_stamping() {
  local home repo fakebin worktree prompt occurrences
  home="$TMP/spawn-home"
  repo="$TMP/project"
  fakebin="$TMP/fakebin"
  worktree="$TMP/spawn-worktree"
  mkdir -p "$home/data/task" "$home/state" "$home/config" "$fakebin"
  cs_git_init_commit "$repo"
  printf -- '- project [local-only] - fixture\n' > "$home/config/projects.md"
  printf 'implement the fixture\nDelivery contract: mode=local-only\n' > "$home/data/task/brief.md"
  # This file's redirect used to land in a config/ nobody created, so the registry
  # fixture was never written and the case passed on a home it never built. These
  # suites run under `set -u` without `set -e`, so a failed redirect is one line of
  # stderr and nothing more - assert the fixture instead of trusting the redirect.
  [ -s "$home/config/projects.md" ] || fail "the project registry fixture was not written"
  [ -s "$home/data/task/brief.md" ] || fail "the brief fixture was not written"

  # An interactive soldier no longer carries the brief in agent start's argv -
  # it cannot: agent start's trailing argv is refused outright on an embedded
  # newline (docs/herdr.md), and every real brief is multi-line. The brief is
  # delivered as a follow-up `agent prompt` instead (bin/cs-prompt-lib.sh's
  # cs_prompt_guarded), so this fake answers that guard's checks with the same
  # minimal empty-composer/idle-agent shape tests/cs-activate.test.sh already
  # established for it, then captures what agent prompt actually receives.
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "status --json")
    printf '%s\n' '{"server":{"protocol":16}}'
    ;;
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
  "agent start")
    printf '%s' "$*" > "$CS_FAKE_SPAWN_LAUNCH"
    printf '{"result":{"agent":{"agent":"codex","agent_status":"idle","interactive_ready":true}}}\n'
    ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"w1:p1","cwd":"%s"}}}\n' "$CS_FAKE_SPAWN_WORKTREE" ;;
  "pane read") printf '%s\n' $'\342\200\272 ' ;;
  "agent get") printf '{"result":{"agent":{"agent":"codex","agent_status":"idle"}}}\n' ;;
  "pane process-info")
    printf '{"result":{"process_info":{"shell_pid":10,"foreground_processes":[{"pid":20,"argv0":"codex"}]}}}\n' ;;
  "agent prompt")
    printf '%s' "${4:-}" > "$CS_FAKE_SPAWN_PROMPT"
    printf '{"result":{"type":"agent_prompted"}}\n' ;;
  *) printf '{}\n' ;;
esac
SH
  chmod +x "$fakebin/herdr"

  env PATH="$fakebin:$PATH" CS_HARNESS_OVERRIDE=codex CS_HOME="$home" CS_DATA_OVERRIDE="$home/data" \
    CS_STATE_OVERRIDE="$home/state" CS_FAKE_SPAWN_WORKTREE="$worktree" \
    CS_FAKE_SPAWN_LAUNCH="$TMP/spawn.launch" CS_FAKE_SPAWN_PROMPT="$TMP/spawn.prompt" \
    "$SPAWN" task "$repo" --mode local-only --yolo off >/dev/null || fail "spawn fixture failed"
  assert_no_grep 'CONSIGLIERE_OP' "$TMP/spawn.launch" \
    "agent start's argv must never carry the encoded brief (it cannot hold multi-line text)"
  prompt=$(cat "$TMP/spawn.prompt")
  [ "$(cs_operational_input_kind "$prompt")" = launch-brief ] || fail "spawn prompt lacks launch-brief kind"
  [ "$(cs_operational_input_body "$prompt")" = "$(cat "$home/data/task/brief.md")" ] \
    || fail "spawn prompt lost brief body"
  # Interactive soldier/capo launches now compute the encoded brief directly in
  # cs-spawn.sh's own shell (one call per launch context: ship, capo, and the
  # relaunch cold-launch fallback = 3); only the headless scout, which stays on
  # the shell-string mechanism permanently, still stamps it via cs-harness-lib.sh.
  occurrences=$(grep -c 'encode launch-brief' "$ROOT/bin/cs-harness-lib.sh")
  [ "$occurrences" -eq 1 ] || fail "the headless scout must be the only cs-harness-lib.sh launch path stamping launch-brief"
  occurrences=$(grep -c 'encode launch-brief' "$ROOT/bin/cs-spawn.sh")
  [ "$occurrences" -eq 3 ] || fail "ship, capo, and the relaunch cold-launch fallback must each stamp launch-brief directly"
  pass "spawn passes a typed launch-brief prompt on every launch path"
}

test_library_and_cli_round_trip
test_exact_compatibility_bytes
test_classifier_types_and_boss_passthrough
test_session_start_stamping
test_turnend_guard_stamping
test_spawn_launch_brief_stamping

pass "canonical operational-input behavior"
