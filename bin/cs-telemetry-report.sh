#!/usr/bin/env bash
# cs-telemetry-report.sh - read-only report over this home's turn telemetry.
#
# Answers the question telemetry exists for: what share of scarce frontier-model
# usage goes to root and capo supervision, and how much of that supervision ended
# in "still working, keep waiting" rather than in an action. The opportunity
# block is an ESTIMATE of what a cheaper supervision tier could absorb, never a
# guaranteed saving: it is an upper bound measured from what already happened.
#
# STRICTLY READ-ONLY. It never mutates telemetry, state, or supervision, and it
# never triggers retention. An absent or empty telemetry file is a clean,
# informative, zero-exit outcome, not an error.
#
# bin/cs-telemetry-lib.sh owns enablement, the storage path, the record schema,
# and the folding rules that produced `purpose` and `outcome`; this script only
# aggregates what is already on disk. docs/telemetry.md is the human contract.
#
# Usage:
#   cs-telemetry-report.sh            print the report for $CS_HOME
#   cs-telemetry-report.sh --json     print the same aggregates as one JSON object
#   cs-telemetry-report.sh --help     print this usage
#
# Exit status:
#   0  the report was produced (including "no telemetry recorded yet")
#   1  jq is missing, so nothing can be aggregated
#   2  a usage error
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
# shellcheck source=bin/cs-telemetry-lib.sh
. "$SCRIPT_DIR/cs-telemetry-lib.sh"

JSON=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    -h|--help)
      awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
      exit 0
      ;;
    *)
      printf 'cs-telemetry-report.sh: unknown argument "%s" (see --help)\n' "$1" >&2
      exit 2
      ;;
  esac
done

cs_telemetry_paths || {
  printf 'cs-telemetry-report.sh: cannot resolve a consigliere home (set CS_HOME)\n' >&2
  exit 2
}
if ! command -v jq >/dev/null 2>&1; then
  printf 'cs-telemetry-report.sh: jq is required to aggregate telemetry\n' >&2
  exit 1
fi

STATUS=$(cs_telemetry_config_status)

# The aggregate, computed once and rendered twice. One jq pass over the raw
# lines: `fromjson?` drops any line that is not a complete JSON object, so a
# partially written or corrupted record can never fail the whole report.
#
# Token sums use each record's total_tokens and contribute nothing where it is
# null, which is why turns.with_usage is reported beside every token figure: a
# token share over a partly instrumented period covers that subset only.
EMPTY_AGGREGATE='{
  "period": {"start": null, "end": null},
  "turns": {"total": 0, "with_usage": 0},
  "tokens": {"total": 0, "input": 0, "cached_input": 0, "output": 0},
  "by_role": {"turns": {}, "tokens": {}},
  "by_purpose": {"turns": {}, "tokens": {}},
  "by_role_purpose": {"turns": {}, "tokens": {}},
  "supervision": {"turns": 0, "tokens": 0,
    "by_wake_kind": {"turns": {}, "tokens": {}},
    "by_outcome": {"turns": {}, "tokens": {}}},
  "opportunity": {}
}'

AGGREGATE=
if [ -f "$CS_TELEMETRY_FILE" ]; then
  AGGREGATE=$(
    jq -R -n '
      def tally(rows; keyf):
        reduce (rows[] | keyf) as $k ({}; .[$k // "unset"] += 1);
      def toks(rows; keyf):
        reduce rows[] as $r ({};
          ($r | keyf) as $k
          | .[$k // "unset"] += (($r.usage.total_tokens // 0)
              | if type == "number" then . else 0 end));
      def sumtok(rows):
        (rows | map(.usage.total_tokens // 0) | map(select(type == "number")) | add // 0);
      def sumfield(rows; f):
        (rows | map(.usage[f] // 0) | map(select(type == "number")) | add // 0);
      def pct($n; $d): (if $d > 0 then (($n * 1000 / $d) | round) / 10 else null end);

      [inputs | fromjson? | select(type == "object") | select(.schema != null)] as $all
      | ($all | map(select(.purpose == "supervision"))) as $sup
      | ($all | map(select(.role == "capo"))) as $capo
      | ($capo | map(select(.purpose == "supervision"))) as $caposup
      | ($sup | map(select(.outcome == "wait" or .outcome == "no_action"))) as $idle
      | ($caposup | map(select(.outcome == "wait" or .outcome == "no_action"))) as $capoidle
      | ($all | length) as $n
      | sumtok($all) as $tk
      | {
          period: {
            start: ($all | map(.timestamp) | map(select(type == "string")) | min),
            end: ($all | map(.timestamp) | map(select(type == "string")) | max)
          },
          turns: {
            total: $n,
            with_usage: ($all | map(select(.usage.total_tokens != null)) | length)
          },
          tokens: {
            total: $tk,
            input: sumfield($all; "input_tokens"),
            cached_input: sumfield($all; "cached_input_tokens"),
            output: sumfield($all; "output_tokens")
          },
          by_role: {turns: tally($all; .role), tokens: toks($all; .role)},
          by_purpose: {turns: tally($all; .purpose), tokens: toks($all; .purpose)},
          by_role_purpose: {
            turns: tally($all; ((.role // "unset") + " / " + (.purpose // "unset"))),
            tokens: toks($all; ((.role // "unset") + " / " + (.purpose // "unset")))
          },
          supervision: {
            turns: ($sup | length),
            tokens: sumtok($sup),
            by_wake_kind: {
              turns: tally($sup; .wake_kind), tokens: toks($sup; .wake_kind)
            },
            by_outcome: {
              turns: tally($sup; .outcome), tokens: toks($sup; .outcome)
            }
          },
          opportunity: (if $n == 0 then {} else {
            capo_share_of_frontier_turns: pct(($capo | length); $n),
            capo_share_of_frontier_usage: pct(sumtok($capo); $tk),
            supervision_share_of_turns: pct(($sup | length); $n),
            supervision_share_of_usage: pct(sumtok($sup); $tk),
            capo_turns_that_are_supervision: pct(($caposup | length); ($capo | length)),
            supervision_ending_in_wait_or_no_action: pct(($idle | length); ($sup | length)),
            all_turns_that_are_supervision_wait_or_no_action: pct(($idle | length); $n),
            all_turns_that_are_capo_supervision_wait_or_no_action: pct(($capoidle | length); $n)
          } end)
        }' < "$CS_TELEMETRY_FILE" 2>/dev/null
  )
fi
# An absent, unreadable, or entirely unparseable file is the same clean
# "nothing recorded yet" outcome, never an error.
[ -n "$AGGREGATE" ] || AGGREGATE=$EMPTY_AGGREGATE

if [ "$JSON" -eq 1 ]; then
  printf '%s' "$AGGREGATE" | jq \
    --argjson schema "$CS_TELEMETRY_SCHEMA" \
    --arg home "$CS_TELEMETRY_HOME" \
    --arg path "$CS_TELEMETRY_FILE" \
    --arg status "$STATUS" \
    '{schema: $schema, home: $home, path: $path, telemetry: $status} + .'
  exit 0
fi

# --- text rendering -----------------------------------------------------------
#
# Column widths match bin/cs-doctor.sh's report style: a fixed-width name column
# so every line stays greppable, then counts and shares right-aligned.

agg() { printf '%s' "$AGGREGATE" | jq -r "$1"; }

# section <title> <turns-path> <tokens-path> <turn-total> <token-total>
section() {
  local title=$1 turns=$2 tokens=$3 tturn=$4 ttok=$5 rows
  rows=$(agg "$turns as \$t | $tokens as \$k
    | (\$t | to_entries | sort_by(-.value, .key)[])
    | [.key, .value, (\$k[.key] // 0)] | @tsv")
  [ -n "$rows" ] || return 0
  printf '\n%s\n' "$title"
  printf '%s\n' "$rows" | awk -F'\t' -v tt="$tturn" -v tk="$ttok" '
    {
      line = sprintf("  %-32s %7d", $1, $2)
      if (tt > 0) line = line sprintf(" %5.0f%%", $2 * 100 / tt)
      else        line = line "       "
      if (tk > 0) line = line sprintf(" %12d %5.0f%%", $3, $3 * 100 / tk)
      print line
    }'
}

TOTAL=$(agg '.turns.total')
TOKENS=$(agg '.tokens.total')
SUP_TURNS=$(agg '.supervision.turns')
SUP_TOKENS=$(agg '.supervision.tokens')

printf 'Consigliere telemetry\n'
printf 'Home:      %s\n' "$CS_TELEMETRY_HOME"
printf 'Storage:   %s\n' "$CS_TELEMETRY_FILE"
printf 'Telemetry: %s\n' "$STATUS"
printf 'Period:    %s -> %s\n' "$(agg '.period.start // "-"')" "$(agg '.period.end // "-"')"
printf 'Turns:     %s recorded, %s carrying token usage\n' "$TOTAL" "$(agg '.turns.with_usage')"

if [ "$TOTAL" = 0 ]; then
  printf '\nNo telemetry recorded yet.\n'
  case "$STATUS" in
    'enabled '*) printf 'Telemetry is on; one record is appended at the end of each turn.\n' ;;
    malformed*) printf 'The explicit host/telemetry.conf is malformed, so telemetry is off (bin/cs-doctor.sh names the problem).\n' ;;
    *) printf 'Enable it with a host/telemetry.conf carrying "enabled true" (docs/telemetry.md).\n' ;;
  esac
  exit 0
fi

if [ "$TOKENS" = 0 ]; then
  printf 'Tokens:    none recorded; every share below is a share of turns\n'
else
  printf 'Tokens:    %s total (%s output, %s input, %s of that cached)\n' \
    "$TOKENS" "$(agg '.tokens.output')" "$(agg '.tokens.input')" "$(agg '.tokens.cached_input')"
fi

section 'Frontier turns by role' '.by_role.turns' '.by_role.tokens' "$TOTAL" "$TOKENS"
section 'Purpose' '.by_purpose.turns' '.by_purpose.tokens' "$TOTAL" "$TOKENS"
section 'Role and purpose' '.by_role_purpose.turns' '.by_role_purpose.tokens' "$TOTAL" "$TOKENS"
section 'Supervision turns by causing wake' '.supervision.by_wake_kind.turns' \
  '.supervision.by_wake_kind.tokens' "$SUP_TURNS" "$SUP_TOKENS"
section 'Supervision outcomes' '.supervision.by_outcome.turns' \
  '.supervision.by_outcome.tokens' "$SUP_TURNS" "$SUP_TOKENS"

printf '\nPotential opportunity (ESTIMATES, never guaranteed savings)\n'
agg '.opportunity | to_entries[] | [(.key | gsub("_"; " ")), (.value // -1)] | @tsv' |
  awk -F'\t' '{ if ($2 < 0) printf "  %-54s %7s\n", $1, "-"; else printf "  %-54s %6.0f%%\n", $1, $2 }'
printf '\n  Read these as an upper bound on what a cheaper supervision tier could absorb.\n'
printf '  wait and no_action together are the supervision that produced no action at all.\n'
