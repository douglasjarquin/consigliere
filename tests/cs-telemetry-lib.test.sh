#!/usr/bin/env bash
# Behavior: bin/cs-telemetry-lib.sh - enablement, storage, the breadcrumb fold,
# harness usage extraction, and retention.
#
# Telemetry is optional measurement, so the properties under test are as much
# about what it must NOT do as what it records: an absent config records nothing,
# a malformed config records nothing and says why, and no failure of any kind
# reaches the caller. tests/cs-telemetry-invariants.test.sh owns the separate
# prime invariant that enabling telemetry does not change supervision.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(cs_test_tmproot cs-telemetry-lib)

# make_home <name> [conf-lines...] - a home with host/, state/, data/ and an
# optional host/telemetry.conf built from the given lines.
make_home() {
  local name=$1 dir
  shift
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/host" "$dir/state" "$dir/data"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$dir/host/telemetry.conf"
  fi
  printf '%s\n' "$dir"
}

# in_home <home> <script> - run <script> with the library sourced exactly as
# bin/cs-turnend-guard.sh sources it, under the strictest shell options a caller
# uses, so an unbound variable or a stray non-zero return in the library fails
# the test loudly.
#
# CS_LOCK_HARNESS_RE widens the session-identity walk to match this test's own
# shell, which is what a real session's codex or claude process is: without it
# nothing in a CI process tree names a harness, breadcrumbs would be dropped as
# unattributable, and the fold cases below would prove nothing.
in_home() {
  local home=$1 script=$2
  CS_HOME="$home" CS_LOCK_HARNESS_RE='bash|zsh|codex|claude' CS_TELEMETRY_DISABLE='' bash -c "
set -eu
. '$ROOT/bin/cs-telemetry-lib.sh'
$script"
}

records() { # <home> - the recorded JSONL
  cat "$1/data/telemetry/turns.jsonl" 2>/dev/null || true
}

crumb_files() { # <home> - every per-session breadcrumb file in the home
  find "$1/state" -maxdepth 1 -name '.telemetry-crumbs-*' 2>/dev/null | sort
}

# Portable "<n> days before now", for aging fixtures past a retention boundary.
iso_days_ago() { # <days>
  local t=$(( $(date -u +%s) - $1 * 86400 ))
  date -u -r "$t" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$t" +%Y-%m-%dT%H:%M:%SZ
}

touch_days_ago() { # <path> <days>
  local t=$(( $(date +%s) - $2 * 86400 )) stamp
  stamp=$(date -r "$t" +%Y%m%d%H%M 2>/dev/null || date -d "@$t" +%Y%m%d%H%M)
  touch -t "$stamp" "$1"
}


# stop_payload <harness> <extra-json> - a Stop payload of that harness's verified
# shape. `turn_id` versus `prompt_id` is the discriminator the emitter reads to
# name the harness that produced the turn (docs/codex.md, docs/claude.md,
# docs/telemetry.md); `ambiguous` carries neither.
stop_payload() {
  local harness=$1 extra=${2:-'{}'}
  case "$harness" in
    codex) jq -cn --argjson x "$extra" '{turn_id:"turn-1"} + $x' ;;
    claude) jq -cn --argjson x "$extra" '{prompt_id:"prompt-1"} + $x' ;;
    *) jq -cn --argjson x "$extra" '$x' ;;
  esac
}

# --- configuration ------------------------------------------------------------

test_config_absent_is_disabled() {
  local home out
  home=$(make_home conf-absent)
  out=$(in_home "$home" 'cs_telemetry_config_status')
  [ "$out" = disabled ] || fail "an absent host/telemetry.conf must read disabled, got '$out'"
  in_home "$home" 'cs_telemetry_crumb wake stale; cs_telemetry_turn_end root ""'
  [ -z "$(records "$home")" ] || fail "disabled telemetry must record nothing"
  assert_absent "$home/data/telemetry" "disabled telemetry must not create the storage directory"
  pass "cs-telemetry: an absent config is disabled and records nothing"
}

test_config_explicit_false_is_disabled() {
  local home out
  home=$(make_home conf-false 'enabled false')
  out=$(in_home "$home" 'cs_telemetry_config_status')
  [ "$out" = disabled ] || fail "enabled false must read disabled, got '$out'"
  in_home "$home" 'cs_telemetry_turn_end root ""'
  [ -z "$(records "$home")" ] || fail "enabled false must record nothing"
  pass "cs-telemetry: an explicit 'enabled false' is disabled"
}

test_config_enabled_defaults_retention() {
  local home out
  home=$(make_home conf-enabled 'enabled true')
  out=$(in_home "$home" 'cs_telemetry_config_status')
  [ "$out" = 'enabled 30' ] || fail "an enabled config with no retain_days must default to 30, got '$out'"
  out=$(in_home "$(make_home conf-retain 'enabled true' 'retain_days 7')" 'cs_telemetry_config_status')
  [ "$out" = 'enabled 7' ] || fail "retain_days must be honored, got '$out'"
  out=$(in_home "$(make_home conf-comment '# a comment' '' 'enabled true')" 'cs_telemetry_config_status')
  [ "$out" = 'enabled 30' ] || fail "blank lines and comments must be ignored, got '$out'"
  pass "cs-telemetry: an enabled config parses, with retention defaulting to 30 days"
}

test_malformed_config_is_disabled_and_specific() {
  local case_name conf out home
  # Each case is "<name>|<line>[;<line>...]" and must read malformed, never
  # enabled: there is no partial enable.
  for case_name in \
    'unknown-key|enabled true;sample_rate 5' \
    'bad-enabled|enabled yes' \
    'extra-field|enabled true extra' \
    'missing-value|enabled' \
    'duplicate|enabled true;enabled false' \
    'no-enabled|retain_days 7' \
    'bad-retain|enabled true;retain_days zero' \
    'zero-retain|enabled true;retain_days 0'; do
    conf=${case_name#*|}
    home=$(make_home "malformed-${case_name%%|*}")
    printf '%s\n' "$conf" | tr ';' '\n' > "$home/host/telemetry.conf"
    out=$(in_home "$home" 'cs_telemetry_config_status')
    case "$out" in
      malformed\ *) ;;
      *) fail "${case_name%%|*}: expected a malformed diagnostic, got '$out'" ;;
    esac
    in_home "$home" 'cs_telemetry_crumb wake stale; cs_telemetry_turn_end root ""'
    [ -z "$(records "$home")" ] || fail "${case_name%%|*}: a malformed config must record nothing"
  done
  pass "cs-telemetry: every malformed config is disabled with a specific diagnostic"
}

# --- record shape -------------------------------------------------------------

test_record_is_valid_jsonl_with_the_full_schema() {
  local home rec field
  home=$(make_home schema 'enabled true')
  in_home "$home" 'cs_telemetry_crumb checkpoint; cs_telemetry_turn_end root ""'
  rec=$(records "$home")
  [ "$(printf '%s\n' "$rec" | wc -l | tr -d ' ')" = 1 ] || fail "one turn must append exactly one line"
  printf '%s' "$rec" | jq -e . >/dev/null || fail "the record must be valid JSON:"$'\n'"$rec"
  for field in schema timestamp event_id role kind home project task_id harness \
    model effort purpose wake_kind wake_kinds outcome duration_ms session_id usage; do
    printf '%s' "$rec" | jq -e "has(\"$field\")" >/dev/null ||
      fail "the record must carry the '$field' field:"$'\n'"$rec"
  done
  for field in input_tokens cached_input_tokens output_tokens reasoning_tokens total_tokens; do
    printf '%s' "$rec" | jq -e ".usage | has(\"$field\")" >/dev/null ||
      fail "usage must carry the '$field' field:"$'\n'"$rec"
  done
  [ "$(printf '%s' "$rec" | jq -r '.schema')" = 1 ] || fail "the record must be schema 1"
  printf '%s' "$rec" | jq -e '.timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' >/dev/null ||
    fail "the timestamp must be a UTC ISO-8601 instant:"$'\n'"$rec"
  printf '%s' "$rec" | jq -e '.event_id | length > 0' >/dev/null || fail "every record needs an event id"
  pass "cs-telemetry: a record is one valid JSON line carrying the whole schema"
}

test_unavailable_fields_are_null_not_invented() {
  local home rec
  home=$(make_home nulls 'enabled true')
  in_home "$home" 'cs_telemetry_crumb checkpoint; cs_telemetry_turn_end root ""'
  rec=$(records "$home")
  # With no harness payload there is no authoritative model, effort, session, or
  # token count, so every one of them must be null rather than guessed.
  printf '%s' "$rec" | jq -e '.model == null and .effort == null and .session_id == null
    and .duration_ms == null and .usage.total_tokens == null' >/dev/null ||
    fail "unavailable values must be null, never invented:"$'\n'"$rec"
  pass "cs-telemetry: unavailable model, effort, session, and token values stay null"
}

test_concurrent_appends_do_not_interleave() {
  local home lines
  home=$(make_home concurrent 'enabled true')
  for _ in $(seq 1 12); do
    in_home "$home" "cs_telemetry_crumb checkpoint; cs_telemetry_turn_end root ''" &
  done
  wait
  lines=$(records "$home" | wc -l | tr -d ' ')
  # Every emitter's record survives: retention runs at this same boundary, and it
  # must abandon its rewrite rather than drop records another emitter appended
  # while it was filtering.
  [ "$lines" = 12 ] || fail "12 concurrent emitters must append 12 lines, got $lines"
  records "$home" | while IFS= read -r line; do
    printf '%s' "$line" | jq -e . >/dev/null || fail "a concurrent append produced a partial line: $line"
  done
  [ "$(records "$home" | jq -r .event_id | sort -u | wc -l | tr -d ' ')" = 12 ] ||
    fail "every record needs its own event id"
  pass "cs-telemetry: concurrent emitters in one home never interleave a partial line"
}

# --- the failure policy -------------------------------------------------------

test_write_failure_never_reaches_the_caller() {
  local home out rc
  home=$(make_home unwritable 'enabled true')
  # A regular file where the storage directory must go makes both the mkdir and
  # the append fail for any user, including root on a CI runner.
  printf 'not a directory\n' > "$home/data/telemetry"
  out=$(in_home "$home" '
cs_telemetry_crumb wake stale
cs_telemetry_turn_end root ""
cs_telemetry_worker_turn_end nope ""
printf "caller survived\n"' 2>&1)
  rc=$?
  expect_code 0 "$rc" "an unwritable telemetry path must not change the caller's exit status"
  [ "$out" = 'caller survived' ] ||
    fail "an unwritable telemetry path must print nothing of its own, got:"$'\n'"$out"
  pass "cs-telemetry: an unwritable storage path leaves the caller's status and output untouched"
}

test_missing_jq_is_a_silent_no_op() {
  local home out rc fakebin
  home=$(make_home nojq 'enabled true')
  fakebin=$(cs_fakebin "$home")
  # A PATH with no jq at all: telemetry cannot serialize, so it must record
  # nothing and stay silent rather than fail its caller.
  out=$(CS_HOME="$home" PATH="$fakebin" CS_TELEMETRY_DISABLE='' /bin/bash -c "
set -eu
. '$ROOT/bin/cs-telemetry-lib.sh'
cs_telemetry_crumb checkpoint
cs_telemetry_turn_end root ''
/bin/echo survived" 2>&1)
  rc=$?
  expect_code 0 "$rc" "a missing jq must not fail the caller"
  assert_contains "$out" survived "a missing jq must not stop the caller"
  [ -z "$(records "$home")" ] || fail "a missing jq must record nothing"
  pass "cs-telemetry: a missing jq is a silent no-op, not a failure"
}

test_a_corrupt_payload_is_ignored() {
  local home rec
  home=$(make_home badpayload 'enabled true')
  in_home "$home" 'cs_telemetry_crumb checkpoint; cs_telemetry_turn_end root "{not json at all"'
  rec=$(records "$home")
  printf '%s' "$rec" | jq -e '.usage.total_tokens == null and .session_id == null' >/dev/null ||
    fail "an unparseable Stop payload must leave usage null, not break the record:"$'\n'"$rec"
  pass "cs-telemetry: an unparseable harness payload still yields a clean record"
}

# --- the fold -----------------------------------------------------------------

# fold_case <name> <role> <crumbs...> - emit one turn and echo
# "<purpose> <outcome> <wake_kind>" from the recorded record.
fold_case() {
  local name=$1 role=$2 home script crumb
  shift 2
  home=$(make_home "fold-$name" 'enabled true')
  script=''
  for crumb in "$@"; do
    script="$script
cs_telemetry_crumb $crumb"
  done
  in_home "$home" "$script
cs_telemetry_turn_end $role ''"
  records "$home" | jq -r '[(.purpose // "-"), (.outcome // "-"), (.wake_kind // "-")] | join(" ")'
}

test_fold_supervision_wait_and_no_action() {
  local got
  got=$(fold_case quiet root checkpoint)
  [ "$got" = 'supervision wait checkpoint' ] ||
    fail "a checkpoint with no drained wake is supervision/wait, got '$got'"
  got=$(fold_case reviewed root 'wake signal' checkpoint)
  [ "$got" = 'supervision no_action signal' ] ||
    fail "a drained wake with no action taken is supervision/no_action, got '$got'"
  pass "cs-telemetry: wait and no_action separate 'still waiting' from 'reviewed, nothing to do'"
}

test_fold_supervision_actions() {
  local got
  got=$(fold_case steered root 'wake signal' steer)
  [ "$got" = 'supervision message_worker signal' ] ||
    fail "a steer after a wake is supervision/message_worker, got '$got'"
  got=$(fold_case spawned root 'wake heartbeat' 'spawn ship')
  [ "$got" = 'supervision dispatch_more heartbeat' ] ||
    fail "a spawn during supervision is dispatch_more, got '$got'"
  got=$(fold_case landed root 'wake check' 'merge pr')
  [ "$got" = 'supervision completed check' ] ||
    fail "a merge during supervision is completed, got '$got'"
  got=$(fold_case recovered root 'wake stale' steer)
  [ "$got" = 'supervision recovery_action stale' ] ||
    fail "an action after a stale wake is recovery_action, got '$got'"
  got=$(fold_case observed root 'wake stale')
  [ "$got" = 'supervision no_action stale' ] ||
    fail "a stale wake that needed nothing is no_action, not recovery_action, got '$got'"
  pass "cs-telemetry: supervision outcomes follow the action that was actually taken"
}

test_fold_wake_kind_provenance() {
  local got home
  got=$(fold_case single root 'wake capo')
  [ "${got##* }" = capo ] || fail "one drained kind must be recorded verbatim, got '$got'"
  got=$(fold_case ckpt root checkpoint)
  [ "${got##* }" = checkpoint ] || fail "a checkpoint-only turn records 'checkpoint', got '$got'"

  # A multi-wake turn must stay inside the queue's vocabulary: wake_kind names
  # the FIRST kind drained so supervision-by-wake still sums to the supervision
  # turn count, and the additive wake_kinds keeps the whole set recoverable.
  home=$(make_home fold-several 'enabled true')
  in_home "$home" '
cs_telemetry_crumb wake signal
cs_telemetry_crumb wake stale
cs_telemetry_crumb wake signal
cs_telemetry_turn_end root ""'
  [ "$(records "$home" | jq -r '.wake_kind')" = signal ] ||
    fail "wake_kind must name the first drained kind:"$'\n'"$(records "$home")"
  [ "$(records "$home" | jq -rc '.wake_kinds')" = '["signal","stale"]' ] ||
    fail "wake_kinds must carry every distinct kind in drain order:"$'\n'"$(records "$home")"

  home=$(make_home fold-one-kind 'enabled true')
  in_home "$home" 'cs_telemetry_crumb wake capo; cs_telemetry_turn_end root ""'
  [ "$(records "$home" | jq -rc '.wake_kinds')" = '["capo"]' ] ||
    fail "a single-wake turn must still carry wake_kinds:"$'\n'"$(records "$home")"

  home=$(make_home fold-no-wake 'enabled true')
  in_home "$home" 'cs_telemetry_crumb checkpoint; cs_telemetry_turn_end root ""'
  [ "$(records "$home" | jq -r '.wake_kinds')" = null ] ||
    fail "a turn that drained no wake must carry a null wake_kinds:"$'\n'"$(records "$home")"
  pass "cs-telemetry: wake provenance uses the queue's own vocabulary"
}

test_fold_non_supervision_purposes() {
  local got
  got=$(fold_case dispatch root 'spawn scout')
  [ "$got" = 'dispatch - -' ] || fail "a bare spawn is dispatch with no outcome, got '$got'"
  got=$(fold_case review root 'teardown ship')
  [ "$got" = 'review - -' ] || fail "a bare teardown is review with no outcome, got '$got'"
  got=$(fold_case bossturn root)
  [ "$got" = 'boss - -' ] || fail "a root turn that supervised nothing is boss work, got '$got'"
  pass "cs-telemetry: dispatch, review, and boss purposes fold from what actually ran"
}

test_fold_unknown_is_preferred_over_a_guess() {
  local got
  # A capo is idle by default and its turns arrive as routed work, so an empty
  # capo turn is genuinely unclassifiable and must not borrow the root rule.
  got=$(fold_case capoidle capo)
  [ "$got" = 'unknown - -' ] || fail "an empty capo turn must be unknown, got '$got'"
  pass "cs-telemetry: an unclassifiable turn records unknown rather than a guess"
}

test_breadcrumbs_are_cleared_per_turn() {
  local home
  home=$(make_home crumbs-cleared 'enabled true')
  in_home "$home" 'cs_telemetry_crumb wake stale; cs_telemetry_turn_end root ""'
  [ -z "$(crumb_files "$home")" ] || fail "the fold must clear the turn's breadcrumbs"
  in_home "$home" 'cs_telemetry_turn_end root ""'
  [ "$(records "$home" | jq -r '.wake_kind' | tr '\n' ' ')" = 'stale null ' ] ||
    fail "a later turn must not inherit the previous turn's wakes:"$'\n'"$(records "$home")"
  pass "cs-telemetry: breadcrumbs are turn-scoped and never leak into the next turn"
}

test_breadcrumbs_are_bounded() {
  local home count file
  home=$(make_home crumbs-bounded 'enabled true')
  CS_HOME="$home" CS_LOCK_HARNESS_RE='bash|zsh|codex|claude' \
    CS_TELEMETRY_MAX_CRUMBS=10 CS_TELEMETRY_DISABLE='' bash -c "
set -eu
. '$ROOT/bin/cs-telemetry-lib.sh'
for i in \$(seq 1 40); do cs_telemetry_crumb wake signal; done"
  file=$(crumb_files "$home")
  [ -n "$file" ] || fail "the breadcrumbs must have been written somewhere"
  count=$(wc -l < "$file" | tr -d ' ')
  [ "$count" -le 10 ] || fail "breadcrumbs must stay bounded, found $count lines"
  pass "cs-telemetry: a home whose turn end never runs cannot grow breadcrumbs unbounded"
}

test_breadcrumbs_are_private_to_their_own_session() {
  local home foreign mine
  home=$(make_home crumbs-per-session 'enabled true')
  # A foreign session's in-flight breadcrumbs: a real supervision turn that has
  # drained a signal wake and is holding a checkpoint, but has not ended its turn.
  foreign="$home/state/.telemetry-crumbs-999999"
  printf 'wake\tsignal\ncheckpoint\t\n' > "$foreign"
  # A second session in the same home ends ITS turn. It must fold only its own
  # breadcrumbs; consuming the foreign ones would attribute another session's
  # supervision to this turn AND leave the real supervisor's turn folding empty.
  in_home "$home" 'cs_telemetry_turn_end root ""'
  assert_present "$foreign" "another session's in-flight breadcrumbs must survive a foreign turn end"
  [ "$(cat "$foreign")" = "$(printf 'wake\tsignal\ncheckpoint\t')" ] ||
    fail "another session's breadcrumbs must be untouched, got:"$'\n'"$(cat "$foreign")"
  [ "$(records "$home" | jq -r '[.purpose, (.wake_kind // "-")] | join(" ")')" = 'boss -' ] ||
    fail "a turn must never be attributed another session's supervision:"$'\n'"$(records "$home")"

  # And the same session's own breadcrumbs are still folded normally.
  # shellcheck disable=SC2016 # CS_TELEMETRY_CRUMBS must expand in the child shell, not here
  mine=$(in_home "$home" 'cs_telemetry_crumbs_resolve; printf "%s\n" "$CS_TELEMETRY_CRUMBS"')
  [ "$mine" != "$foreign" ] || fail "the session key must differ from the seeded foreign one"
  in_home "$home" 'cs_telemetry_crumb wake stale; cs_telemetry_turn_end root ""'
  [ "$(records "$home" | tail -1 | jq -r '.wake_kind')" = stale ] ||
    fail "a session must still fold its own breadcrumbs:"$'\n'"$(records "$home" | tail -1)"
  pass "cs-telemetry: one session can neither fold nor delete another session's breadcrumbs"
}

test_breadcrumbs_survive_a_recycled_pid() {
  local home key pid recycled
  home=$(make_home crumbs-recycled-pid 'enabled true')
  # shellcheck disable=SC2016 # CS_TELEMETRY_CRUMBS must expand in the child shell, not here
  key=$(in_home "$home" 'cs_telemetry_crumbs_resolve; printf "%s\n" "${CS_TELEMETRY_CRUMBS##*/.telemetry-crumbs-}"')
  pid=${key%%-*}
  [ -n "$pid" ] && [ "$pid" != "$key" ] ||
    fail "the session key must bind the harness pid to a reuse-proof identity, got '$key'"

  # A DEAD session that once resolved this very pid. Its identity differed, so
  # its file must read as another session's however the pid landed - otherwise a
  # recycled pid folds a dead session's supervision into this turn's record. The
  # bare-pid name is exactly what the key used to be, so it is the regression.
  for recycled in "$home/state/.telemetry-crumbs-$pid" \
                  "$home/state/.telemetry-crumbs-$pid-0000000000000000"; do
    printf 'wake\tsignal\ncheckpoint\t\n' > "$recycled"
  done
  in_home "$home" 'cs_telemetry_turn_end root ""'
  [ "$(records "$home" | jq -r '[.purpose, (.wake_kind // "-")] | join(" ")')" = 'boss -' ] ||
    fail "a recycled pid must not fold a dead session's breadcrumbs:"$'\n'"$(records "$home")"
  assert_present "$home/state/.telemetry-crumbs-$pid" \
    "a bare-pid breadcrumb file belongs to no live session and must not be consumed"
  assert_present "$home/state/.telemetry-crumbs-$pid-0000000000000000" \
    "a same-pid different-identity breadcrumb file must not be consumed"
  pass "cs-telemetry: the session key binds the pid to its identity, so a recycled pid cannot collide"
}

test_stale_breadcrumbs_are_discarded_not_folded() {
  local home crumbs stamp t
  home=$(make_home crumbs-stale 'enabled true')
  t=$(( $(date +%s) - 7200 ))
  stamp=$(date -r "$t" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$t" +%Y%m%d%H%M.%S)
  # One process, so the breadcrumbs and the fold resolve the SAME session key -
  # this is the session's own file, backdated to look like the leftovers of a
  # session that died mid-turn and whose key something later resolved again.
  # Folding it would credit this turn with supervision from another one.
  # shellcheck disable=SC2016 # CS_TELEMETRY_CRUMBS must expand in the child shell, not here
  crumbs=$(in_home "$home" '
cs_telemetry_crumb wake signal
cs_telemetry_crumb checkpoint
cs_telemetry_crumbs_resolve
touch -t '"$stamp"' "$CS_TELEMETRY_CRUMBS"
cs_telemetry_turn_end root ""
printf "%s\n" "$CS_TELEMETRY_CRUMBS"')
  [ -n "$crumbs" ] || fail "the session must have resolved a breadcrumb path"
  [ "$(records "$home" | jq -r '[.purpose, (.wake_kind // "-"), (.outcome // "-")] | join(" ")')" = 'boss - -' ] ||
    fail "breadcrumbs older than one turn must not be folded:"$'\n'"$(records "$home")"
  assert_absent "$crumbs" "stale breadcrumbs must be removed, not left for the retention sweep"

  # The same guard must not truncate a real turn: a fresh file still folds.
  in_home "$home" 'cs_telemetry_crumb wake signal; cs_telemetry_turn_end root ""'
  [ "$(records "$home" | tail -1 | jq -r '.wake_kind')" = signal ] ||
    fail "a fresh breadcrumb file must still fold:"$'\n'"$(records "$home" | tail -1)"
  pass "cs-telemetry: breadcrumbs older than one plausible turn are discarded rather than folded"
}

# --- role attribution ---------------------------------------------------------

test_role_root_and_capo() {
  local home
  home=$(make_home role-root 'enabled true')
  in_home "$home" 'cs_telemetry_turn_end root ""'
  [ "$(records "$home" | jq -r '[.role, (.kind // "-"), (.task_id // "-")] | join(" ")')" = 'root - -' ] ||
    fail "a root turn carries role=root and no task kind:"$'\n'"$(records "$home")"

  home=$(make_home role-capo 'enabled true')
  printf 'infra\n' > "$home/.cs-capo-home"
  in_home "$home" 'cs_telemetry_turn_end capo ""'
  [ "$(records "$home" | jq -r '[.role, .kind, .task_id] | join(" ")')" = 'capo capo infra' ] ||
    fail "a capo turn names itself from its own home marker:"$'\n'"$(records "$home")"
  pass "cs-telemetry: root turns never fall into the capo bucket, and a capo names itself"
}

test_role_ship_and_scout_come_from_meta() {
  local home
  home=$(make_home role-worker 'enabled true')
  cs_write_meta "$home/state/build.meta" 'kind=ship' 'harness=codex' \
    'project=/tmp/projects/niceuptime'
  cs_write_meta "$home/state/look.meta" 'kind=scout' 'harness=claude' \
    'project=/tmp/projects/consigliere'
  in_home "$home" 'cs_telemetry_worker_turn_end build ""; cs_telemetry_worker_turn_end look ""'
  [ "$(records "$home" | jq -r 'select(.task_id == "build")
      | [.role, .kind, .purpose, .harness, .project] | join(" ")')" \
    = 'ship ship implementation codex niceuptime' ] ||
    fail "a ship turn must read its identity from state/<id>.meta:"$'\n'"$(records "$home")"
  # Consigliere selects no model or effort, so a turn whose harness session
  # states neither records null rather than a value nobody chose.
  [ "$(records "$home" | jq -r 'select(.task_id == "look")
      | [.role, .purpose, .harness, (.model // "null"), (.effort // "null"), .project] | join(" ")')" \
    = 'scout research claude null null consigliere' ] ||
    fail "a scout turn must record research and never invent a model:"$'\n'"$(records "$home")"
  pass "cs-telemetry: ship and scout turns attribute from the authoritative task metadata"
}

test_worker_without_meta_records_nothing() {
  local home
  home=$(make_home worker-nometa 'enabled true')
  in_home "$home" 'cs_telemetry_worker_turn_end ghost ""'
  [ -z "$(records "$home")" ] || fail "a worker with no metadata must record nothing rather than guess"
  in_home "$home" 'cs_telemetry_worker_turn_end "../escape" ""'
  [ -z "$(records "$home")" ] || fail "a task id outside the id vocabulary must record nothing"
  pass "cs-telemetry: a worker turn with no authoritative metadata records nothing"
}

# --- harness usage ------------------------------------------------------------

test_codex_usage_is_summed_from_the_rollout() {
  local home roll payload
  home=$(make_home usage-codex 'enabled true')
  roll="$home/rollout.jsonl"
  {
    printf '%s\n' '{"type":"turn_context","payload":{"model":"gpt-5.6-sol","effort":"xhigh"}}'
    printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":7,"reasoning_output_tokens":3,"total_tokens":107}}}}'
    printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":60,"output_tokens":13,"reasoning_output_tokens":5,"total_tokens":213}}}}'
    printf '%s\n' '{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","duration_ms":4321}}'
  } > "$roll"
  payload=$(stop_payload codex "$(jq -cn --arg t "$roll" \
    '{session_id:"sess-codex",transcript_path:$t,model:"gpt-5.6-sol"}')")
  in_home "$home" "cs_telemetry_turn_end root '$payload'"
  [ "$(records "$home" | jq -r '[.harness, .usage.input_tokens, .usage.cached_input_tokens,
      .usage.output_tokens, .usage.reasoning_tokens, .usage.total_tokens,
      .duration_ms, .model, .effort, .session_id] | join(" ")')" \
    = 'codex 300 100 20 8 320 4321 gpt-5.6-sol xhigh sess-codex' ] ||
    fail "codex usage must sum every token_count in the turn window:"$'\n'"$(records "$home")"
  pass "cs-telemetry: codex usage, duration, model, and effort come from the rollout"
}

test_claude_usage_dedupes_streaming_snapshots() {
  local home tr payload
  home=$(make_home usage-claude 'enabled true')
  tr="$home/transcript.jsonl"
  # Two distinct assistant messages, the first recorded three times as claude
  # streams it. Summing rows blind would triple that message's tokens.
  {
    printf '%s\n' '{"type":"assistant","timestamp":"2026-08-08T12:00:00.000Z","effort":"xhigh","message":{"id":"msg_a","model":"claude-opus-5","usage":{"input_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":900,"output_tokens":50}}}'
    printf '%s\n' '{"type":"assistant","timestamp":"2026-08-08T12:00:01.000Z","effort":"xhigh","message":{"id":"msg_a","model":"claude-opus-5","usage":{"input_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":900,"output_tokens":50}}}'
    printf '%s\n' '{"type":"assistant","timestamp":"2026-08-08T12:00:02.000Z","effort":"xhigh","message":{"id":"msg_a","model":"claude-opus-5","usage":{"input_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":900,"output_tokens":50}}}'
    printf '%s\n' '{"type":"assistant","timestamp":"2026-08-08T12:00:04.500Z","effort":"xhigh","message":{"id":"msg_b","model":"claude-opus-5","usage":{"input_tokens":2,"cache_creation_input_tokens":10,"cache_read_input_tokens":90,"output_tokens":8}}}'
  } > "$tr"
  payload=$(stop_payload claude "$(jq -cn --arg t "$tr" \
    '{session_id:"sess-claude",transcript_path:$t,effort:{level:"xhigh"}}')")
  in_home "$home" "cs_telemetry_turn_end root '$payload'"
  # input = (5+100+900) + (2+10+90) = 1107; cached = 900 + 90 = 990; output = 58.
  [ "$(records "$home" | jq -r '[.harness, .usage.input_tokens, .usage.cached_input_tokens,
      .usage.output_tokens, (.usage.reasoning_tokens // "null"), .usage.total_tokens,
      .duration_ms, .model, .effort, .session_id] | join(" ")')" \
    = 'claude 1107 990 58 null 1165 4500 claude-opus-5 xhigh sess-claude' ] ||
    fail "claude usage must dedupe by message id and fold cache tokens into input:"$'\n'"$(records "$home")"
  pass "cs-telemetry: claude usage dedupes streaming snapshots and normalizes cache tokens"
}

test_usage_cursor_bounds_the_next_turn() {
  local home tr payload
  home=$(make_home usage-cursor 'enabled true')
  tr="$home/transcript.jsonl"
  printf '%s\n' '{"type":"assistant","timestamp":"2026-08-08T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}' > "$tr"
  payload=$(stop_payload claude "$(jq -cn --arg t "$tr" \
    '{session_id:"sess-cursor",transcript_path:$t,effort:{level:"high"}}')")
  in_home "$home" "cs_telemetry_turn_end root '$payload'"
  printf '%s\n' '{"type":"assistant","timestamp":"2026-08-08T12:01:00.000Z","message":{"id":"m2","model":"claude-opus-5","usage":{"input_tokens":30,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":2}}}' >> "$tr"
  in_home "$home" "cs_telemetry_turn_end root '$payload'"
  [ "$(records "$home" | jq -r '.usage.input_tokens' | tr '\n' ' ')" = '10 30 ' ] ||
    fail "the second turn must count only the bytes appended since the first:"$'\n'"$(records "$home")"
  assert_present "$home/state/.telemetry-cursor-sess-cursor" "the per-session cursor must persist"

  # A third turn adds no new transcript bytes at all. Its usage is genuinely
  # unknown and must be null, but the model and effort this session already
  # stated authoritatively are carried forward by the cursor rather than lost.
  in_home "$home" "cs_telemetry_turn_end root '$payload'"
  [ "$(records "$home" | tail -1 | jq -r '[(.usage.total_tokens // "null"), .model, .effort] | join(" ")')" \
    = 'null claude-opus-5 high' ] ||
    fail "an empty window must carry the session's known model and effort with null usage:"$'\n'"$(records "$home" | tail -1)"
  pass "cs-telemetry: a per-session cursor attributes each turn only its own new transcript bytes"
}

test_usage_never_records_conversation_content() {
  local home tr payload rec
  home=$(make_home privacy 'enabled true')
  tr="$home/transcript.jsonl"
  printf '%s\n' '{"type":"assistant","timestamp":"2026-08-08T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-5","content":[{"type":"text","text":"SECRET-TRANSCRIPT-TEXT"}],"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}' > "$tr"
  payload=$(stop_payload claude "$(jq -cn --arg t "$tr" \
    '{session_id:"sess-priv",transcript_path:$t,last_assistant_message:"SECRET-PAYLOAD-TEXT",cwd:"/tmp"}')")
  in_home "$home" "cs_telemetry_turn_end root '$payload'"
  rec=$(records "$home")
  assert_not_contains "$rec" SECRET-TRANSCRIPT-TEXT "a record must never reproduce transcript content"
  assert_not_contains "$rec" SECRET-PAYLOAD-TEXT "a record must never reproduce the Stop payload's message"
  pass "cs-telemetry: only numbers, model, and effort leave the transcript read"
}

test_harness_comes_from_the_payload_not_the_dispatch_pin() {
  local home tr payload
  home=$(make_home harness-shape 'enabled true')
  # host/harness.conf pins what this home DISPATCHES with. It is no evidence
  # about the harness that produced the turn being measured, so a payload that
  # contradicts it must win - otherwise the record names the wrong harness and
  # the transcript goes to the wrong parser.
  printf 'claude\n' > "$home/host/harness.conf"
  tr="$home/rollout.jsonl"
  printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":11,"cached_input_tokens":1,"output_tokens":2,"reasoning_output_tokens":0,"total_tokens":13}}}}' > "$tr"
  payload=$(stop_payload codex "$(jq -cn --arg t "$tr" '{session_id:"sess-a",transcript_path:$t,model:"gpt-5.6-sol"}')")
  in_home "$home" "cs_telemetry_turn_end root '$payload'"
  [ "$(records "$home" | jq -r '[.harness, .usage.total_tokens] | join(" ")')" = 'codex 13' ] ||
    fail "a codex-shaped payload must record harness=codex and parse the rollout:"$'\n'"$(records "$home")"

  home=$(make_home harness-shape-claude 'enabled true')
  printf 'codex\n' > "$home/host/harness.conf"
  tr="$home/transcript.jsonl"
  printf '%s\n' '{"type":"assistant","timestamp":"2026-08-08T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":7,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":3}}}' > "$tr"
  payload=$(stop_payload claude "$(jq -cn --arg t "$tr" '{session_id:"sess-b",transcript_path:$t,effort:{level:"high"}}')")
  in_home "$home" "cs_telemetry_turn_end root '$payload'"
  [ "$(records "$home" | jq -r '[.harness, .usage.total_tokens] | join(" ")')" = 'claude 10' ] ||
    fail "a claude-shaped payload must record harness=claude and parse the transcript:"$'\n'"$(records "$home")"

  # Ambiguous: neither discriminating field. A null harness is honest; a guessed
  # one plus null usage is not, so usage extraction is skipped entirely.
  home=$(make_home harness-shape-ambiguous 'enabled true')
  printf 'codex\n' > "$home/host/harness.conf"
  tr="$home/transcript.jsonl"
  printf '%s\n' '{"type":"assistant","timestamp":"2026-08-08T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":7,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":3}}}' > "$tr"
  payload=$(stop_payload none "$(jq -cn --arg t "$tr" '{session_id:"sess-c",transcript_path:$t}')")
  in_home "$home" "cs_telemetry_turn_end root '$payload'"
  [ "$(records "$home" | jq -r '[(.harness // "null"), (.usage.total_tokens // "null"), .session_id] | join(" ")')" \
    = 'null null sess-c' ] ||
    fail "an ambiguous payload must record a null harness and no usage:"$'\n'"$(records "$home")"

  # Both fields present is equally ambiguous, and must not pick a side.
  home=$(make_home harness-shape-both 'enabled true')
  payload=$(jq -cn '{session_id:"sess-d",turn_id:"t",prompt_id:"p"}')
  in_home "$home" "cs_telemetry_turn_end root '$payload'"
  [ "$(records "$home" | jq -r '.harness // "null"')" = null ] ||
    fail "a payload carrying both discriminators must record a null harness:"$'\n'"$(records "$home")"
  pass "cs-telemetry: the emitting harness is read from the Stop payload, never from the dispatch pin"
}

test_an_ambiguous_harness_does_not_consume_the_usage_window() {
  local home tr payload ambiguous
  home=$(make_home harness-ambiguous-cursor 'enabled true')
  tr="$home/transcript.jsonl"
  printf '%s\n' '{"type":"assistant","timestamp":"2026-08-08T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":7,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":3}}}' > "$tr"
  # An ambiguous payload has no parser, so it must not advance the cursor either.
  # Advancing it would forfeit this window's tokens permanently: the NEXT turn,
  # even one whose payload is perfectly unambiguous, would start past them.
  ambiguous=$(stop_payload none "$(jq -cn --arg t "$tr" '{session_id:"sess-amb",transcript_path:$t}')")
  in_home "$home" "cs_telemetry_turn_end root '$ambiguous'"
  assert_absent "$home/state/.telemetry-cursor-sess-amb" \
    "an ambiguous harness must leave the usage cursor untouched"

  payload=$(stop_payload claude "$(jq -cn --arg t "$tr" '{session_id:"sess-amb",transcript_path:$t,effort:{level:"high"}}')")
  in_home "$home" "cs_telemetry_turn_end root '$payload'"
  [ "$(records "$home" | tail -1 | jq -r '[.harness, .usage.total_tokens] | join(" ")')" = 'claude 10' ] ||
    fail "the turn after an ambiguous one must still count the whole window:"$'\n'"$(records "$home" | tail -1)"
  pass "cs-telemetry: an ambiguous harness skips usage extraction without forfeiting the window"
}

# --- retention ----------------------------------------------------------------

test_retention_drops_records_past_retain_days() {
  local home old new
  home=$(make_home retention 'enabled true' 'retain_days 2')
  mkdir -p "$home/data/telemetry"
  old=$(date -u -r 0 +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '1970-01-01T00:00:00Z')
  new=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  {
    printf '{"schema":1,"timestamp":"%s","event_id":"old","role":"root","usage":{}}\n' "$old"
    printf '{"schema":1,"timestamp":"%s","event_id":"new","role":"root","usage":{}}\n' "$new"
  } > "$home/data/telemetry/turns.jsonl"
  in_home "$home" 'cs_telemetry_prune'
  [ "$(records "$home" | jq -r .event_id | tr '\n' ' ')" = 'new ' ] ||
    fail "retention must drop records past retain_days and keep the rest:"$'\n'"$(records "$home")"
  pass "cs-telemetry: retention drops aged records and keeps recent ones"
}

# Portable inode number, the same Darwin/GNU split bin/cs-telemetry-lib.sh uses
# for mtime. Identity of the file, not of its content: a replaced file is a new
# inode even when every byte matches.
file_inode() { # <path>
  if [ "$(uname 2>/dev/null)" = Darwin ]; then
    stat -f %i "$1" 2>/dev/null
  else
    stat -c %i "$1" 2>/dev/null
  fi
}

test_retention_never_rewrites_a_file_it_would_not_change() {
  local home file before inode_before inode_after
  home=$(make_home retention-noop 'enabled true')
  mkdir -p "$home/data/telemetry"
  file="$home/data/telemetry/turns.jsonl"
  {
    printf '{"schema":1,"timestamp":"%s","event_id":"a","role":"root","usage":{}}\n' "$(iso_days_ago 1)"
    printf '{"schema":1,"timestamp":"%s","event_id":"b","role":"root","usage":{}}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$file"
  before=$(records "$home")
  inode_before=$(file_inode "$file")
  in_home "$home" 'cs_telemetry_prune'
  inode_after=$(file_inode "$file")
  [ "$(records "$home")" = "$before" ] ||
    fail "a prune with nothing past retain_days must leave every record alone:"$'\n'"$(records "$home")"
  # And it must leave the same FILE, not an identical copy. Replacing the live
  # file is exactly how a record an unlocked emitter appended goes missing, so
  # retention never spends that risk on a pass that drops nothing.
  [ "$inode_before" = "$inode_after" ] ||
    fail "retention replaced a file it dropped nothing from ($inode_before -> $inode_after)"
  pass "cs-telemetry: retention leaves the live file in place when nothing ages out"
}

test_retention_ages_out_session_cursors_and_crumbs() {
  local home old new old_crumbs new_crumbs
  home=$(make_home retention-cursors 'enabled true' 'retain_days 1')
  mkdir -p "$home/data/telemetry"
  old="$home/state/.telemetry-cursor-ancient"
  new="$home/state/.telemetry-cursor-current"
  old_crumbs="$home/state/.telemetry-crumbs-11111"
  new_crumbs="$home/state/.telemetry-crumbs-22222"
  printf '0\t\t\n' > "$old"
  printf '0\t\t\n' > "$new"
  printf 'checkpoint\t\n' > "$old_crumbs"
  printf 'checkpoint\t\n' > "$new_crumbs"
  # Per-session state older than the retention window can no longer bound
  # anything that is still recorded, so it is dropped with the records it
  # belonged to. A dead session's breadcrumbs are nobody's to fold.
  touch -t 202001010000 "$old" "$old_crumbs"
  in_home "$home" 'cs_telemetry_prune'
  assert_absent "$old" "an aged-out session cursor must be removed with the records it bounded"
  assert_present "$new" "a current session cursor must survive retention"
  assert_absent "$old_crumbs" "an aged-out session's breadcrumbs must not accumulate forever"
  assert_present "$new_crumbs" "a current session's breadcrumbs must survive retention"
  pass "cs-telemetry: retention ages out per-session cursors and breadcrumbs with the records"
}

test_retention_runs_at_most_once_per_interval() {
  local home stamp before
  home=$(make_home retention-interval 'enabled true' 'retain_days 1')
  mkdir -p "$home/data/telemetry"
  printf '{"schema":1,"timestamp":"1970-01-01T00:00:00Z","event_id":"old","role":"root","usage":{}}\n' \
    > "$home/data/telemetry/turns.jsonl"
  stamp="$home/data/telemetry/.pruned"
  printf '%s\n' "$(date -u +%s)" > "$stamp"
  before=$(records "$home")
  in_home "$home" 'cs_telemetry_prune'
  [ "$(records "$home")" = "$before" ] ||
    fail "a fresh prune stamp must skip the rewrite entirely"
  pass "cs-telemetry: retention respects its own interval instead of rewriting every turn"
}

test_retention_skips_when_its_lock_is_held() {
  local home before
  home=$(make_home retention-lock 'enabled true' 'retain_days 1')
  mkdir -p "$home/data/telemetry/.prune.lock"
  printf '{"schema":1,"timestamp":"1970-01-01T00:00:00Z","event_id":"old","role":"root","usage":{}}\n' \
    > "$home/data/telemetry/turns.jsonl"
  before=$(records "$home")
  in_home "$home" 'cs_telemetry_prune'
  [ "$(records "$home")" = "$before" ] ||
    fail "retention must skip silently while another prune holds the lock"
  assert_present "$home/data/telemetry/.prune.lock" "a fresh lock must be left for its live holder"
  pass "cs-telemetry: retention never blocks on a held lock; it skips and retries next turn"
}

test_retention_reclaims_a_leaked_lock_instead_of_wedging() {
  local home lock
  home=$(make_home retention-leaked-lock 'enabled true' 'retain_days 1')
  mkdir -p "$home/data/telemetry"
  lock="$home/data/telemetry/.prune.lock"
  printf '{"schema":1,"timestamp":"1970-01-01T00:00:00Z","event_id":"old","role":"root","usage":{}}\n' \
    > "$home/data/telemetry/turns.jsonl"
  # A prune that was hard-killed between mkdir and rmdir - a Stop-hook timeout
  # is enough. Left alone this wedges retention forever and telemetry then grows
  # without bound with no diagnostic anywhere.
  mkdir "$lock"
  touch_days_ago "$lock" 3
  in_home "$home" 'cs_telemetry_prune'
  [ -z "$(records "$home")" ] ||
    fail "a lock older than one prune interval must be reclaimed, not wedge retention:"$'\n'"$(records "$home")"
  assert_absent "$lock" "a completed prune must leave no lock behind"
  pass "cs-telemetry: a leaked prune lock is reclaimed rather than wedging retention forever"
}

test_retention_releases_its_lock_when_the_work_aborts() {
  local home out
  home=$(make_home retention-abort 'enabled true' 'retain_days 1')
  mkdir -p "$home/data/telemetry"
  printf '{"schema":1,"timestamp":"1970-01-01T00:00:00Z","event_id":"old","role":"root","usage":{}}\n' \
    > "$home/data/telemetry/turns.jsonl"
  # The locked section dies mid-flight. The lock must still come back, or the
  # very next turn end sees a held lock and retention stops running.
  out=$(in_home "$home" 'cs_telemetry_prune_locked() { exit 9; }; cs_telemetry_prune; printf "caller survived\n"')
  [ "$out" = 'caller survived' ] ||
    fail "an aborted prune must not take its caller down with it, got:"$'\n'"$out"
  assert_absent "$home/data/telemetry/.prune.lock" \
    "an aborted prune must release its lock rather than leave retention wedged"
  pass "cs-telemetry: an abnormal exit inside the prune releases its lock"
}

test_retain_days_is_one_base_ten_number_for_every_sweep() {
  local home old_cursor new_cursor
  # A leading zero used to mean two different things downstream: bash arithmetic
  # reads "09" as an invalid octal literal and aborts the prune mid-lock, while
  # `find -mtime +09` reads base 10. Both sweeps must agree on one number.
  [ "$(in_home "$(make_home retain-octal-9 'enabled true' 'retain_days 09')" 'cs_telemetry_config_status')" \
    = 'enabled 9' ] || fail "retain_days 09 must normalize to 9"
  [ "$(in_home "$(make_home retain-octal-12 'enabled true' 'retain_days 012')" 'cs_telemetry_config_status')" \
    = 'enabled 12' ] || fail "retain_days 012 must normalize to 12, never to octal 10"
  [ "$(in_home "$(make_home retain-padded 'enabled true' 'retain_days 0030')" 'cs_telemetry_config_status')" \
    = 'enabled 30' ] || fail "a zero-padded retain_days must normalize to its base-10 value"
  case "$(in_home "$(make_home retain-all-zero 'enabled true' 'retain_days 000')" 'cs_telemetry_config_status')" in
    malformed\ *) ;;
    *) fail "retain_days 000 is zero days and must be malformed" ;;
  esac

  home=$(make_home retain-octal-sweeps 'enabled true' 'retain_days 09')
  mkdir -p "$home/data/telemetry"
  {
    printf '{"schema":1,"timestamp":"%s","event_id":"old","role":"root","usage":{}}\n' "$(iso_days_ago 10)"
    printf '{"schema":1,"timestamp":"%s","event_id":"new","role":"root","usage":{}}\n' "$(iso_days_ago 5)"
  } > "$home/data/telemetry/turns.jsonl"
  old_cursor="$home/state/.telemetry-cursor-old"
  new_cursor="$home/state/.telemetry-cursor-new"
  printf '0\t\t\n' > "$old_cursor"
  printf '0\t\t\n' > "$new_cursor"
  touch_days_ago "$old_cursor" 10
  touch_days_ago "$new_cursor" 5
  in_home "$home" 'cs_telemetry_prune'
  [ "$(records "$home" | jq -r .event_id | tr '\n' ' ')" = 'new ' ] ||
    fail "the record sweep must use 9 days, not an octal reading:"$'\n'"$(records "$home")"
  assert_absent "$old_cursor" "the cursor sweep must drop the same 10-day-old state the record sweep dropped"
  assert_present "$new_cursor" "the cursor sweep must keep 5-day-old state, exactly as the record sweep did"
  assert_absent "$home/data/telemetry/.prune.lock" "a leading-zero retain_days must not abort the prune mid-lock"
  pass "cs-telemetry: retain_days is normalized once, so the record and cursor sweeps never disagree"
}

test_config_absent_is_disabled
test_config_explicit_false_is_disabled
test_config_enabled_defaults_retention
test_malformed_config_is_disabled_and_specific
test_record_is_valid_jsonl_with_the_full_schema
test_unavailable_fields_are_null_not_invented
test_concurrent_appends_do_not_interleave
test_write_failure_never_reaches_the_caller
test_missing_jq_is_a_silent_no_op
test_a_corrupt_payload_is_ignored
test_fold_supervision_wait_and_no_action
test_fold_supervision_actions
test_fold_wake_kind_provenance
test_fold_non_supervision_purposes
test_fold_unknown_is_preferred_over_a_guess
test_breadcrumbs_are_cleared_per_turn
test_breadcrumbs_are_bounded
test_breadcrumbs_are_private_to_their_own_session
test_breadcrumbs_survive_a_recycled_pid
test_stale_breadcrumbs_are_discarded_not_folded
test_role_root_and_capo
test_role_ship_and_scout_come_from_meta
test_worker_without_meta_records_nothing
test_codex_usage_is_summed_from_the_rollout
test_claude_usage_dedupes_streaming_snapshots
test_usage_cursor_bounds_the_next_turn
test_usage_never_records_conversation_content
test_harness_comes_from_the_payload_not_the_dispatch_pin
test_an_ambiguous_harness_does_not_consume_the_usage_window
test_retention_drops_records_past_retain_days
test_retention_never_rewrites_a_file_it_would_not_change
test_retention_ages_out_session_cursors_and_crumbs
test_retention_runs_at_most_once_per_interval
test_retention_skips_when_its_lock_is_held
test_retention_reclaims_a_leaked_lock_instead_of_wedging
test_retention_releases_its_lock_when_the_work_aborts
test_retain_days_is_one_base_ten_number_for_every_sweep
