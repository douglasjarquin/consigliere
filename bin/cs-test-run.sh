#!/usr/bin/env bash
# cs-test-run.sh - single owner of consigliere's behavior-test selection and the
# complete-regression coverage guard.
#
# consigliere's suite is small and its runner is deliberately simple and serial:
# there are no shards, families, or backends. Every tests/*.test.sh belongs to
# exactly one lane:
#
#   portable    - hermetic. Runs on every hosted OS (Ubuntu + stock macOS Bash).
#                 The default lane: a new test is portable unless explicitly
#                 categorized otherwise here, so a new test can never be silently
#                 omitted from CI.
#   real-herdr  - needs a real isolated Herdr lab (CS_TEST_HERDR_LIVE=1). Runs in
#                 the dedicated required Herdr CI lane, never in portable.
#   live-codex  - needs a real Codex agent and credentials (CS_TEST_CODEX_LIVE=1).
#                 OPT-IN ONLY: never run in hosted CI. The coverage guard reports
#                 it as explicitly excluded so it is visibly skipped, not silently
#                 dropped.
#   live-claude - needs a real Claude agent and credentials (CS_TEST_CLAUDE_LIVE=1).
#                 OPT-IN ONLY: never run in hosted CI, same exclusion as live-codex.
#
# Selection modes (exactly one):
#   cs-test-run.sh --portable                 run every portable (hermetic) test, serial
#   cs-test-run.sh --herdr                    run the real-herdr lane, serial
#   cs-test-run.sh --lane <name>              run a named lane (portable|real-herdr|live-codex|live-claude)
#   cs-test-run.sh tests/<name>.test.sh ...   run the given scripts, serial
#
# Inspection (no execution):
#   cs-test-run.sh --list --portable          print selected script paths and exit 0
#   cs-test-run.sh --list --lane <name>
#   cs-test-run.sh --list-lanes               print the known lane names
#   cs-test-run.sh --lane-of tests/<name>.test.sh   print one script's lane
#   cs-test-run.sh --check-coverage           prove the lanes partition the inventory
#
# Options:
#   --fail-on-gate-skip <token>
#       After each script, fail the run if any output line contains <token>
#       (substring match). The required Herdr lane passes the env-gate skip
#       phrase so a misconfigured lane that skips instead of running cannot pass
#       as a false green.
#
# Exit status: 0 on success; 1 on a test failure or a matched gate-skip token;
# 2 on a usage/selection error.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

MODE=
LANE=
LIST_ONLY=0
LANE_OF=
FAIL_ON_GATE_SKIP=
SCRIPTS=()

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'cs-test-run: %s\n' "$*" >&2
  exit 2
}

log() {
  printf 'cs-test-run: %s\n' "$*" >&2
}

# The lane for one tests/*.test.sh basename. Default is portable so a new test is
# always categorized and runnable; the two live-only lanes are named explicitly.
# This case statement is the single owner of the test categorization.
lane_for_basename() {
  case "$1" in
    cs-herdr-lib-live.test.sh)
      printf '%s\n' real-herdr
      ;;
    cs-lifecycle-live.test.sh)
      printf '%s\n' live-codex
      ;;
    cs-lifecycle-claude-live.test.sh)
      printf '%s\n' live-claude
      ;;
    *)
      printf '%s\n' portable
      ;;
  esac
}

list_known_lanes() {
  cat <<'EOF'
portable
real-herdr
live-codex
live-claude
EOF
}

all_repo_tests() {
  # Deterministic lexical order (same as bash glob under LC_ALL=C).
  local f
  for f in tests/*.test.sh; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done | LC_ALL=C sort
}

normalize_script_path() {
  local p=$1
  case "$p" in
    tests/*) printf '%s\n' "$p" ;;
    ./tests/*) printf '%s\n' "${p#./}" ;;
    *.test.sh)
      if [ -f "tests/$p" ]; then
        printf 'tests/%s\n' "$p"
      else
        printf '%s\n' "$p"
      fi
      ;;
    *) printf '%s\n' "$p" ;;
  esac
}

add_script() {
  local p existing
  p=$(normalize_script_path "$1")
  for existing in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    [ "$existing" = "$p" ] && return 0
  done
  SCRIPTS+=("$p")
}

select_lane() {
  local want=$1 s found=0
  case "$want" in
    portable|real-herdr|live-codex|live-claude) ;;
    *) die "unknown lane '$want' (see --list-lanes)" ;;
  esac
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if [ "$(lane_for_basename "$(basename "$s")")" = "$want" ]; then
      add_script "$s"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ] || die "lane '$want' selected no tests"
}

run_coverage_guard() {
  local tmp lane s dup_overlap=0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/cs-test-coverage.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  all_repo_tests | LC_ALL=C sort -u >"$tmp/all"

  : >"$tmp/union"
  for lane in portable real-herdr live-codex live-claude; do
    : >"$tmp/lane.$lane"
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      if [ "$(lane_for_basename "$(basename "$s")")" = "$lane" ]; then
        printf '%s\n' "$s" >>"$tmp/lane.$lane"
      fi
    done <"$tmp/all"
    LC_ALL=C sort -u "$tmp/lane.$lane" -o "$tmp/lane.$lane"
    cat "$tmp/lane.$lane" >>"$tmp/union"
  done

  # No script may appear in two lanes.
  LC_ALL=C sort "$tmp/union" | uniq -d >"$tmp/dups"
  if [ -s "$tmp/dups" ]; then
    log "coverage guard: scripts categorized into more than one lane:"
    cat "$tmp/dups" >&2
    dup_overlap=1
  fi

  LC_ALL=C sort -u "$tmp/union" >"$tmp/union_sorted"
  local missing extra
  missing=$(comm -23 "$tmp/all" "$tmp/union_sorted" || true)
  extra=$(comm -13 "$tmp/all" "$tmp/union_sorted" || true)
  if [ -n "$missing" ] || [ -n "$extra" ] || [ "$dup_overlap" -ne 0 ]; then
    log "coverage guard: the portable + real-herdr + live-codex + live-claude lanes must equal tests/*.test.sh exactly, with no script in two lanes"
    [ -z "$missing" ] || { log "missing from every lane:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "categorized but not in the inventory:"; printf '%s\n' "$extra" >&2; }
    return 1
  fi

  # The live-only scripts must exist and be excluded from the hosted lanes.
  local herdr_count codex_count claude_count portable_count total
  herdr_count=$(wc -l <"$tmp/lane.real-herdr" | tr -d ' ')
  codex_count=$(wc -l <"$tmp/lane.live-codex" | tr -d ' ')
  claude_count=$(wc -l <"$tmp/lane.live-claude" | tr -d ' ')
  portable_count=$(wc -l <"$tmp/lane.portable" | tr -d ' ')
  total=$(wc -l <"$tmp/all" | tr -d ' ')

  if [ "$codex_count" -gt 0 ]; then
    log "coverage guard: live-codex is opt-in only and excluded from hosted CI:"
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      log "  excluded (CS_TEST_CODEX_LIVE): $s"
    done <"$tmp/lane.live-codex"
  fi
  if [ "$claude_count" -gt 0 ]; then
    log "coverage guard: live-claude is opt-in only and excluded from hosted CI:"
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      log "  excluded (CS_TEST_CLAUDE_LIVE): $s"
    done <"$tmp/lane.live-claude"
  fi

  printf 'CS_TEST_COVERAGE ok total=%s portable=%s real-herdr=%s live-codex=%s live-claude=%s\n' \
    "$total" "$portable_count" "$herdr_count" "$codex_count" "$claude_count"
  return 0
}

detect_gate_skip_token() {
  local file=$1 token=$2
  [ -n "$token" ] || return 1
  grep -F -q "$token" "$file" 2>/dev/null
}

run_scripts() {
  [ "${#SCRIPTS[@]}" -gt 0 ] || die "no scripts selected to run"
  local total=0 failed=0 gate_hits=0 s out rc
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/cs-test-run.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  for s in "${SCRIPTS[@]}"; do
    [ -f "$s" ] || die "test script not found: $s"
    total=$((total + 1))
    out="$tmp/out.$total"
    log "running $s"
    rc=0
    bash "$s" >"$out" 2>&1 || rc=$?
    cat "$out"
    if [ "$rc" -ne 0 ]; then
      failed=$((failed + 1))
      log "FAIL ($rc): $s"
      continue
    fi
    if [ -n "$FAIL_ON_GATE_SKIP" ] && detect_gate_skip_token "$out" "$FAIL_ON_GATE_SKIP"; then
      gate_hits=$((gate_hits + 1))
      log "GATE-SKIP FAIL: $s emitted '$FAIL_ON_GATE_SKIP' but this lane must run it"
    fi
  done

  printf 'CS_TEST_RUN total=%s failed=%s gate_skip=%s\n' "$total" "$failed" "$gate_hits"
  [ "$failed" -eq 0 ] && [ "$gate_hits" -eq 0 ]
}

# --- argument parsing -------------------------------------------------------

while [ "$#" -gt 0 ]; do
  case "$1" in
    --portable)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=lane
      LANE=portable
      shift
      ;;
    --herdr)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=lane
      LANE=real-herdr
      shift
      ;;
    --lane)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      [ "$#" -gt 1 ] || die "--lane requires a name"
      MODE=lane
      LANE=$2
      shift 2
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --list-lanes)
      list_known_lanes
      exit 0
      ;;
    --lane-of)
      [ "$#" -gt 1 ] || die "--lane-of requires a script path"
      LANE_OF=$2
      shift 2
      ;;
    --check-coverage)
      [ -z "$MODE" ] || die "--check-coverage takes no selection mode"
      MODE=coverage
      shift
      ;;
    --fail-on-gate-skip)
      [ "$#" -gt 1 ] || die "--fail-on-gate-skip requires a token"
      FAIL_ON_GATE_SKIP=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      die "unknown option: $1"
      ;;
    *)
      [ -z "$MODE" ] || [ "$MODE" = scripts ] || die "only one selection mode is allowed"
      MODE=scripts
      add_script "$1"
      shift
      ;;
  esac
done

if [ -n "$LANE_OF" ]; then
  base=$(basename "$(normalize_script_path "$LANE_OF")")
  [ -f "tests/$base" ] || die "not a tracked test: $LANE_OF"
  lane_for_basename "$base"
  exit 0
fi

case "$MODE" in
  coverage)
    run_coverage_guard
    exit $?
    ;;
  lane)
    select_lane "$LANE"
    ;;
  scripts)
    ;;
  '')
    usage
    die "no selection mode given"
    ;;
esac

if [ "$LIST_ONLY" -eq 1 ]; then
  printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}"
  exit 0
fi

run_scripts
