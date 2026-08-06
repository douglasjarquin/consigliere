#!/usr/bin/env bash
# cs-fleet-view.sh - read-only fleet review for heartbeat wakes and boss briefs.
#
# One command, two renderings of the same data:
#   (default)  a human-readable markdown fleet review
#   --json     the underlying structured snapshot, schema `cs-fleet-view.v1`
#
# What it gathers (all bounded, all read-only):
#   backlog  - compact listing via tasks-axi when the configured backend selects
#              it and the tool is installed, else title lines from
#              config/backlog.md; plus per-section headline counts.
#   tasks    - one row per state/<id>.meta: kind, optional mode/yolo, project, pr
#              (bin/cs-meta-lib.sh), endpoint liveness (herdr pane exists plus
#              corroborated agent status via bin/cs-herdr-lib.sh), the
#              authoritative current state from bin/cs-crew-state.sh, the keyed
#              open-decision fold from bin/cs-classify-lib.sh's
#              status_open_decisions (a later unrelated event never masks a
#              still-open boss decision), the scout report pointer at
#              data/<id>/report.md, and the last status EVENT (history, never
#              current-state truth).
#   capos    - registered rows from host/capos.md, parsed by the single owner
#              bin/cs-capo-registry-lib.sh. Each capo home gets a bounded
#              structured read (in-flight child meta count, backlog headline
#              counts) ONLY after validation: the recorded home must exist and
#              carry the .cs-capo-home marker. Anything unreadable or invalid is
#              classified state=unknown with a reason, never guessed. A registry
#              that cannot be read at all sets `capos.error` and says so in the
#              render rather than reporting an empty fleet.
#              A capo's idle endpoint is healthy; do not treat quiet as stale.
#
# Read-only always: no session lock, no wake drain, no teardown, no merges, no
# backlog mutation, no report writes.
#
# Env (tests and large fleets):
#   CS_FLEET_BACKLOG_LIMIT   max backlog listing lines shown (default 30)
#   CS_FLEET_CAPOS           max capo registry rows read (default 20)
#   CS_FLEET_REGISTRY_BYTES  max bytes read from host/capos.md (default 65536)
#   CS_FLEET_CAPO_MAX_BYTES  max bytes read from a capo backlog (default 262144)
#   CS_CREW_STATE_BIN        current-state reader override (tests stub it)
#   CS_FLEET_NOW             fixed generated timestamp override
#
# Consumers: AGENTS.md section 8 heartbeat review ("review the whole fleet
# from bin/cs-fleet-view.sh") and any point-in-time boss status brief.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-capo-registry-lib.sh
. "$SCRIPT_DIR/cs-capo-registry-lib.sh"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
BACKLOG="$CONFIG/backlog.md"
CAPO_REG="$HOST_DIR/capos.md"
NOW=${CS_FLEET_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}

CS_FLEET_BACKLOG_LIMIT=${CS_FLEET_BACKLOG_LIMIT:-30}
CS_FLEET_CAPOS=${CS_FLEET_CAPOS:-20}
CS_FLEET_REGISTRY_BYTES=${CS_FLEET_REGISTRY_BYTES:-65536}
CS_FLEET_CAPO_MAX_BYTES=${CS_FLEET_CAPO_MAX_BYTES:-262144}
for bound in \
  "CS_FLEET_BACKLOG_LIMIT=$CS_FLEET_BACKLOG_LIMIT" \
  "CS_FLEET_CAPOS=$CS_FLEET_CAPOS" \
  "CS_FLEET_REGISTRY_BYTES=$CS_FLEET_REGISTRY_BYTES" \
  "CS_FLEET_CAPO_MAX_BYTES=$CS_FLEET_CAPO_MAX_BYTES"; do
  case "${bound#*=}" in
    ''|*[!0-9]*|0) echo "cs-fleet-view: ${bound%%=*} must be a positive integer" >&2; exit 2 ;;
  esac
done

usage() {
  cat <<'EOF'
usage: cs-fleet-view.sh [--json]

Render a read-only fleet review: backlog, every state/<id>.meta with endpoint
liveness and authoritative current state, open keyed decisions, scout report
and PR pointers, and registered capo homes (bounded, marker-validated read).
--json prints the underlying snapshot (schema cs-fleet-view.v1).
EOF
}

MODE_OUT=human
case "${1:-}" in
  '') ;;
  --json) MODE_OUT=json ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "cs-fleet-view: jq not found" >&2; exit 1; }

# shellcheck source=bin/cs-herdr-lib.sh
. "$SCRIPT_DIR/cs-herdr-lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$SCRIPT_DIR/cs-meta-lib.sh"
# shellcheck source=bin/cs-classify-lib.sh
. "$SCRIPT_DIR/cs-classify-lib.sh"
CS_CREW_STATE_BIN="${CS_CREW_STATE_BIN:-$SCRIPT_DIR/cs-crew-state.sh}"

bool_json() { if [ "$1" = 1 ]; then printf 'true'; else printf 'false'; fi; }

lines_json() {  # stdin lines -> JSON array of strings
  jq -R -s '[splits("\n") | select(length > 0)]'
}

# --- backlog -----------------------------------------------------------------

backlog_backend() {
  case "$(cat "$CONFIG/backlog-backend.conf" 2>/dev/null || true)" in
    manual) printf 'manual' ;;
    *) printf 'tasks-axi' ;;
  esac
}

backlog_counts() {  # <file> -> "in_flight queued done" (bounded read on stdin ok)
  awk '
    /^##[[:space:]]+In flight[[:space:]]*$/ { s = "i"; next }
    /^##[[:space:]]+Queued[[:space:]]*$/    { s = "q"; next }
    /^##[[:space:]]+Done[[:space:]]*$/      { s = "d"; next }
    /^##/ { s = ""; next }
    s != "" && /^[-*][[:space:]]/ { c[s]++ }
    END { printf "%d %d %d\n", c["i"], c["q"], c["d"] }
  '
}

backlog_title_lines() {  # <file>
  awk -v max="$CS_FLEET_BACKLOG_LIMIT" '
    /^##[[:space:]]+(In flight|Queued|Done)[[:space:]]*$/ { print; sect = 1; next }
    /^##/ { sect = 0; next }
    sect && /^[-*][[:space:]]/ {
      total++
      if (shown < max) { print; shown++ }
      next
    }
    END {
      if (total == 0) print "(no backlog item title lines found)"
      else if (total > shown) printf "(shown %d of %d item title lines)\n", shown, total
    }
  ' "$1"
}

backlog_json() {
  local present=0 source=none listing='' counts='0 0 0' out rc
  if [ -f "$BACKLOG" ]; then
    present=1
    counts=$(backlog_counts < "$BACKLOG")
    if [ "$(backlog_backend)" = tasks-axi ] && command -v tasks-axi >/dev/null 2>&1; then
      out=$(tasks-axi list --file "$BACKLOG" --limit "$CS_FLEET_BACKLOG_LIMIT" \
        --fields blocked_by,hold_kind,hold_reason 2>&1); rc=$?
      if [ "$rc" -eq 0 ]; then
        source=tasks-axi
        listing=$out
      fi
    fi
    if [ "$source" = none ]; then
      source=title-lines
      listing=$(backlog_title_lines "$BACKLOG")
    fi
  fi
  jq -n \
    --arg path "$BACKLOG" \
    --arg backend "$(backlog_backend)" \
    --arg source "$source" \
    --argjson present "$(bool_json "$present")" \
    --argjson in_flight "$(printf '%s' "$counts" | cut -d' ' -f1)" \
    --argjson queued "$(printf '%s' "$counts" | cut -d' ' -f2)" \
    --argjson done_ "$(printf '%s' "$counts" | cut -d' ' -f3)" \
    --argjson listing "$(printf '%s\n' "$listing" | lines_json)" \
    '{path:$path,present:$present,backend:$backend,listing_source:$source,
      counts:{in_flight:$in_flight,queued:$queued,done:$done_},listing:$listing}'
}

# --- tasks -------------------------------------------------------------------

crew_state_line() {  # <id> -> the one canonical "state: … · source: … · …" line
  CS_HOME="$CS_HOME" CS_STATE_OVERRIDE="$STATE" CS_DATA_OVERRIDE="$DATA" \
    "$CS_CREW_STATE_BIN" "$1" 2>/dev/null | head -1 || true
}

task_json_stream() {
  local meta id kind mode yolo project worktree pane workspace pr sep raw rest
  local cstate csource cdetail pane_exists agent report last_line decisions headless
  sep=' · '
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(cs_meta_get "$meta" kind || echo ship)
    mode=$(cs_meta_get "$meta" mode || true)
    yolo=$(cs_meta_get "$meta" yolo || true)
    project=$(cs_meta_get "$meta" project || true)
    worktree=$(cs_meta_get "$meta" worktree || true)
    pane=$(cs_meta_get "$meta" pane || true)
    workspace=$(cs_meta_get "$meta" workspace || true)
    pr=$(cs_meta_get "$meta" pr || true)
    # A headless scout runs codex exec / claude -p: it never presents a steerable
    # TUI pane. Surface the marker so the render does not imply one can be steered.
    headless=$(cs_meta_get "$meta" headless || true)

    pane_exists=null
    agent=unknown
    if [ -n "$pane" ]; then
      if cs_herdr_pane_exists "$pane"; then
        pane_exists=true
        agent=$(cs_herdr_agent_busy_state "$pane" 2>/dev/null || printf 'unknown')
      else
        pane_exists=false
      fi
    fi

    raw=$(crew_state_line "$id")
    cstate=unknown; csource=none; cdetail=''
    case "$raw" in
      state:\ *"$sep"source:\ *)
        rest=${raw#state: }
        cstate=${rest%%"$sep"source: *}
        rest=${rest#*"$sep"source: }
        case "$rest" in
          *"$sep"*) csource=${rest%%"$sep"*}; cdetail=${rest#*"$sep"} ;;
          *) csource=$rest ;;
        esac
        ;;
    esac

    decisions=$(status_open_decisions "$STATE/$id.status" | jq -R -s '
      [ splits("\n") | select(length > 0)
        | (capture("^(?<key>[^\t]*)\t(?<verb>[^\t]*)\t(?<summary>.*)$")?)
        | select(. != null) ]')
    last_line=$(last_status_line "$STATE/$id.status")
    report="$DATA/$id/report.md"

    jq -n \
      --arg id "$id" --arg kind "$kind" --arg mode "$mode" --arg yolo "$yolo" \
      --arg project "$project" --arg worktree "$worktree" \
      --arg pane "$pane" --arg workspace "$workspace" --arg pr "$pr" \
      --arg agent "$agent" \
      --arg state "$cstate" --arg source "$csource" --arg detail "$cdetail" --arg raw "$raw" \
      --arg report "$report" --arg last_verb "$(status_line_verb "$last_line")" \
      --arg last_note "$(status_line_note "$last_line")" --arg last_raw "$last_line" \
      --argjson pane_exists "$pane_exists" \
      --argjson headless "$(bool_json "$([ "$headless" = 1 ] && echo 1 || echo 0)")" \
      --argjson worktree_present "$(bool_json "$([ -n "$worktree" ] && [ -d "$worktree" ] && echo 1 || echo 0)")" \
      --argjson report_present "$(bool_json "$([ -f "$report" ] && echo 1 || echo 0)")" \
      --argjson open_decisions "$decisions" \
      '{id:$id,kind:$kind,mode:$mode,yolo:$yolo,headless:$headless,
        project:(if $project == "" then null else $project end),
        worktree:{path:(if $worktree == "" then null else $worktree end),present:$worktree_present},
        endpoint:{pane:(if $pane == "" then null else $pane end),workspace:(if $workspace == "" then null else $workspace end),
          exists:$pane_exists,agent:$agent},
        current_state:{state:$state,source:$source,detail:$detail,raw:$raw},
        open_decisions:$open_decisions,
        pr:(if $pr == "" then null else $pr end),
        report:{path:$report,present:$report_present},
        last_event:{verb:$last_verb,note:$last_note,raw:$last_raw}}'
  done
}

# --- capos -------------------------------------------------------------------

capo_record_json() {  # <id> <home> <scope>
  local id=$1 home=$2 scope=$3 cstate=ok reason='' children=null blog='null'
  local m n bl counts
  if [ -z "$home" ]; then
    cstate=unknown; reason="registry entry has no home"
  elif [ ! -d "$home" ]; then
    cstate=unknown; reason="home directory missing"
  elif [ ! -f "$home/.cs-capo-home" ]; then
    cstate=unknown; reason="not a marked capo home (.cs-capo-home missing)"
  elif [ ! -r "$home" ] || [ ! -x "$home" ]; then
    cstate=unknown; reason="home directory unreadable"
  else
    n=0
    for m in "$home/state"/*.meta; do
      [ -e "$m" ] && n=$((n + 1))
    done
    children=$n
    bl="$home/config/backlog.md"
    if [ -f "$bl" ]; then
      if counts=$(head -c "$CS_FLEET_CAPO_MAX_BYTES" "$bl" 2>/dev/null | backlog_counts); then
        blog=$(jq -n --arg path "$bl" \
          --argjson in_flight "$(printf '%s' "$counts" | cut -d' ' -f1)" \
          --argjson queued "$(printf '%s' "$counts" | cut -d' ' -f2)" \
          --argjson done_ "$(printf '%s' "$counts" | cut -d' ' -f3)" \
          '{path:$path,present:true,in_flight:$in_flight,queued:$queued,done:$done_}')
      else
        cstate=unknown; reason="capo backlog unreadable"
      fi
    else
      blog=$(jq -n --arg path "$bl" '{path:$path,present:false,in_flight:0,queued:0,done:0}')
    fi
  fi
  jq -n --arg id "$id" --arg home "$home" --arg scope "$scope" \
    --arg state "$cstate" --arg reason "$reason" \
    --argjson children "$children" --argjson backlog "$blog" \
    '{id:$id,home:(if $home == "" then null else $home end),
      scope:(if $scope == "" then null else $scope end),
      state:$state,reason:(if $reason == "" then null else $reason end),
      children_in_flight:$children,backlog:$backlog}'
}

malformed_capo_record_json() {  # <raw registry line>
  jq -n --arg reason "malformed registry entry: $1" \
    '{id:null,home:null,scope:null,state:"unknown",reason:$reason,
      children_in_flight:null,backlog:null}'
}

# The registry read fails CLOSED. An unreadable or symlinked routing table used
# to render as present with zero records, which reads exactly like "this fleet
# has no capos" - so every registered capo silently vanished from the review.
# It now carries an `error` the render surfaces. A row that does not parse
# becomes a visible unknown record for the same reason.
capos_json() {
  local records status id home scope raw shown=0 total=0
  if ! cs_capo_registry_exists "$CAPO_REG"; then
    jq -n --arg path "$CAPO_REG" \
      '{path:$path,present:false,records:[],truncated:false,error:null}'
    return 0
  fi
  # Availability is checked HERE, in this shell, so its reason survives; the
  # capture below runs in a subshell that could not hand one back.
  if ! cs_capo_registry_available "$CAPO_REG"; then
    jq -n --arg path "$CAPO_REG" --arg error "$CS_CAPO_REGISTRY_ERROR" \
      '{path:$path,present:true,records:[],truncated:false,error:$error}'
    return 0
  fi
  if ! records=$(cs_capo_registry_records "$CAPO_REG" "$CS_FLEET_REGISTRY_BYTES"); then
    jq -n --arg path "$CAPO_REG" --arg error "capo registry could not be read: $CAPO_REG" \
      '{path:$path,present:true,records:[],truncated:false,error:$error}'
    return 0
  fi
  [ -z "$records" ] || total=$(printf '%s\n' "$records" | wc -l | tr -d ' ')
  {
    if [ -n "$records" ]; then
      while IFS=$'\t' read -r status id home scope raw; do
        [ "$shown" -lt "$CS_FLEET_CAPOS" ] || break
        shown=$((shown + 1))
        if [ "$status" = ok ]; then
          capo_record_json "$id" "$home" "$scope"
        else
          malformed_capo_record_json "$raw"
        fi
      done <<< "$records"
    fi
  } | jq -s \
    --arg path "$CAPO_REG" --argjson total "$total" --argjson cap "$CS_FLEET_CAPOS" \
    '{path:$path,present:true,records:.,truncated:($total > $cap),error:null}'
}

# --- assemble and render -----------------------------------------------------

SNAPSHOT=$(jq -n \
  --arg schema "cs-fleet-view.v1" \
  --arg generated "$NOW" \
  --arg home "$CS_HOME" \
  --argjson backlog "$(backlog_json)" \
  --argjson tasks "$(task_json_stream | jq -s 'sort_by(.id)')" \
  --argjson capos "$(capos_json)" \
  '{schema:$schema,generated:$generated,home:$home,backlog:$backlog,tasks:$tasks,capos:$capos}')

if [ "$MODE_OUT" = json ]; then
  printf '%s\n' "$SNAPSHOT"
  exit 0
fi

printf '%s\n' "$SNAPSHOT" | jq -r '
  def dash($v): if $v == null or $v == "" then "-" else $v end;
  def endpoint_of($t):
    (if $t.endpoint.exists == null then "no pane recorded"
     elif $t.endpoint.exists then "present / \($t.endpoint.agent)"
     else "ABSENT" end)
    + (if $t.headless then " · headless (not steerable)" else "" end);
  def artifact($t):
    if $t.pr != null then $t.pr
    elif $t.report.present then $t.report.path
    else "-" end;
  def task_row($t):
    "| \($t.id) | \($t.kind) | \($t.current_state.state) (\($t.current_state.source)) | \(endpoint_of($t)) | \(dash($t.mode))/\(dash($t.yolo)) | \(dash($t.project)) | \(artifact($t)) | \(dash($t.current_state.detail)) |";
  def capo_row($c):
    "| \(dash($c.id)) | \($c.state) | \(dash($c.children_in_flight)) | \(if $c.backlog == null then "-" else "\($c.backlog.in_flight)/\($c.backlog.queued)/\($c.backlog.done)" end) | \(dash($c.home)) | \(dash($c.reason)) |";
  ([.tasks[] | . as $t | (.open_decisions[] | {id:$t.id,key,verb,summary})]) as $decisions |

  "# Fleet Review",
  "",
  "Schema: \(.schema) · Generated: \(.generated)",
  "Home: \(.home)",
  "",
  "## Backlog (\(.backlog.counts.in_flight) in flight, \(.backlog.counts.queued) queued, \(.backlog.counts.done) done)",
  (if .backlog.present | not then "ABSENT: \(.backlog.path)"
   else "compact listing (\(.backlog.listing_source); max shown bounded):", .backlog.listing[] end),
  "",
  "## Tasks (state/<id>.meta)",
  (if (.tasks | length) == 0 then "No live task metadata found."
   else
    "| ID | Kind | Current | Endpoint | Mode/Yolo | Project | Artifact | Detail |",
    "| --- | --- | --- | --- | --- | --- | --- | --- |",
    (.tasks[] | task_row(.))
   end),
  "",
  "## Open decisions (keyed status fold; a later unrelated event never clears these)",
  (if ($decisions | length) == 0 then "None."
   else ($decisions[] | "- \(.id) [key=\(.key)] \(.verb): \(.summary)") end),
  "",
  "## Capos (idle endpoint is healthy; route by scope, read state not chat)",
  (if .capos.present | not then "No capos provisioned from this home."
   elif .capos.error != null then "UNREADABLE capo registry: \(.capos.error). Registered capos are NOT listed below; this is not an empty fleet."
   elif (.capos.records | length) == 0 then "Registry present, no registered capos."
   else
    "| ID | State | In-flight children | Backlog i/q/d | Home | Reason |",
    "| --- | --- | --- | --- | --- | --- |",
    (.capos.records[] | capo_row(.)),
    (if .capos.truncated then "(capo listing truncated at the CS_FLEET_CAPOS bound)" else empty end)
   end)
'
