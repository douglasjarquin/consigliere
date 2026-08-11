#!/usr/bin/env bash
# Scaffold a soldier brief or persistent capo charter at
# data/<task-id>/brief.md under the active consigliere home.
# For ordinary tasks, the standard Setup/Rules/Definition-of-done contract is
# filled in. Consigliere then replaces the {TASK} placeholder with the task
# description, acceptance criteria, and context, and may adjust other sections
# when the task genuinely deviates (e.g. working an existing external PR
# instead of shipping a new one).
# Usage: cs-brief.sh <task-id> <repo-name> --mode <no-mistakes|direct-PR|local-only> [--issue <n>] [--herdr-lab]
#        cs-brief.sh <task-id> <repo-name> --scout [--herdr-lab]
#        cs-brief.sh <task-id> --capo {<project>...|--no-projects}
#   --mode is REQUIRED on a ship scaffold and refused on --scout and --capo,
#   whose deliverables have no delivery mode. There is no fallback: a missing or
#   out-of-set mode is a refusal, because a silently defaulted definition of done
#   is exactly the drift this flag exists to prevent.
#   There is no --yolo flag on any scaffold. yolo governs consigliere's own
#   approval behaviour, never the worker's contract, so a brief must never carry
#   it; passing it is refused rather than ignored.
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no push, no PR) and the worktree is scratch.
#   --capo writes a persistent capo charter. The project list is cloned into
#   the capo home, while the natural-language scope tells the main consigliere
#   when to route work there; routine churn stays in its own home;
#   boss-relevant escalations and marked from-consigliere replies append to
#   this home's status file.
#   --no-projects writes a project-less charter for a domain whose subject is
#   the consigliere repo itself. It is mutually exclusive with a project list,
#   and omitting both still fails loudly so an accidental omission is never
#   silent.
#   Set CS_CAPO_CHARTER='<charter>' to fill the charter text.
#   Set CS_CAPO_SCOPE='<scope>' to write a routing scope distinct from the
#   charter text.
#   --herdr-lab is mandatory when the task will issue herdr lifecycle commands.
#   It adds the hard isolation contract backed by bin/cs-herdr-lab.sh.
#   The flag must be explicit because {TASK} is filled after scaffolding and
#   the caller-supplied repo string cannot reliably identify this repo. Briefs
#   made without it carry a loud declaration so an omitted contract cannot be
#   silent.
# For ship tasks, the definition of done is shaped by the explicit --mode, and
# the brief's last line records it verbatim as
# "Delivery contract: mode=<mode>" (bin/cs-delivery-lib.sh owns that literal).
# cs-spawn.sh reads that line back and refuses a spawn whose --mode disagrees, so
# the worker's definition of done and the task's durable record cannot diverge.
# The line sits at the very end, past every section a caller edits when it fills
# in {TASK}, so filling the brief in cannot clobber it.
# The three modes:
#   no-mistakes  implement -> needs-review: (consigliere reviews the commit and
#                triggers validation) -> pipeline -> PR -> boss merge.
#                The commit is reported as needs-review, never done: a keyed
#                open state keeps an unreviewed commit visible, where done:
#                read as finished and let a missed review idle a lane 56m on
#                2026-08-02 (niceuptime-590).
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> boss merge
#   local-only   implement on branch, stop and report "ready in branch" (no
#                push/PR); boss approves, consigliere merges to local main
# Ship briefs begin with a worktree-isolation assertion before any commit.
# The task branch cs/<task-id> is created by cs-spawn.sh's herdr worktree, so
# briefs verify the branch rather than creating it.
# Scout tasks have no delivery mode - their deliverable is a report, not a merge.
# Every scaffold's status protocol distinguishes the configured
# declared-external-wait verb (CS_CLASSIFY_PAUSED_VERB, default "paused") from
# "blocked:": pause for a known external wait expected to clear on its own,
# blocked when consigliere must act.
# Ship tasks include a project-memory section so durable project-intrinsic
# learnings can be committed to AGENTS.md through the project's delivery path.
# Refuses to overwrite an existing brief.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/cs-marker-lib.sh
. "$SCRIPT_DIR/cs-marker-lib.sh"
# shellcheck source=bin/cs-classify-lib.sh
. "$SCRIPT_DIR/cs-classify-lib.sh"
PAUSED_VERB=${CS_CLASSIFY_PAUSED_VERB:-$CS_CLASSIFY_PAUSED_VERB_DEFAULT}
# shellcheck source=bin/cs-delivery-lib.sh
. "$SCRIPT_DIR/cs-delivery-lib.sh"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
KIND=ship
HERDR_LAB=0
NO_PROJECTS=0
ISSUE=
MODE=
POS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --scout) KIND=scout ;;
    --capo) KIND=capo ;;
    --herdr-lab) HERDR_LAB=1 ;;
    --no-projects) NO_PROJECTS=1 ;;
    --issue) ISSUE=${2:?--issue requires an issue number}; shift ;;
    --issue=*) ISSUE=${1#--issue=} ;;
    --mode) MODE=${2:?--mode requires a value}; shift ;;
    --mode=*) MODE=${1#--mode=} ;;
    # yolo is consigliere's own approval posture, not the worker's contract, so
    # it must never reach a brief. Refuse it instead of quietly treating it as a
    # positional argument.
    --yolo|--yolo=*)
      echo "error: --yolo is not a brief flag; yolo governs consigliere's approval behaviour and is passed to cs-spawn.sh, never written into a brief" >&2
      exit 1 ;;
    *) POS+=("$1") ;;
  esac
  shift
done
ID=${POS[0]}
if [ -n "$ISSUE" ]; then
  case "$ISSUE" in *[!0-9]*) echo "error: --issue must be a number, got '$ISSUE'" >&2; exit 1 ;; esac
fi
if [ -n "$ISSUE" ] && [ "$KIND" != ship ]; then
  echo "error: --issue applies only to ship briefs (an issue is closed by a merged PR)" >&2
  exit 1
fi

# The delivery contract is an explicit per-task decision with no fallback: a ship
# brief states it or is refused, and a scout or capo deliverable has none to state.
if [ "$KIND" = ship ]; then
  if [ -z "$MODE" ]; then
    echo "error: a ship brief requires --mode <$CS_DELIVERY_MODES>; the delivery contract is decided per task, not derived from the project registry" >&2
    exit 1
  fi
  if ! cs_delivery_mode_valid "$MODE"; then
    echo "error: --mode must be one of $CS_DELIVERY_MODES, got '$MODE'" >&2
    exit 1
  fi
elif [ -n "$MODE" ]; then
  echo "error: --mode applies only to ship briefs; a $KIND deliverable has no delivery mode" >&2
  exit 1
fi

if [ "$KIND" = capo ] && [ "$HERDR_LAB" -eq 1 ]; then
  echo "error: --herdr-lab applies only to soldier ship or scout briefs" >&2
  exit 1
fi

if [ "$NO_PROJECTS" -eq 1 ] && [ "$KIND" != capo ]; then
  echo "error: --no-projects applies only to --capo charters" >&2
  exit 1
fi

BRIEF="$DATA/$ID/brief.md"
[ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
mkdir -p "$DATA/$ID"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

STATUS_FILE=$(shell_quote "$STATE/$ID.status")

if [ "$KIND" = capo ]; then
CAPO_PROJECTS=""
idx=1
while [ "$idx" -lt "${#POS[@]}" ]; do
  CAPO_PROJECTS="${CAPO_PROJECTS}${CAPO_PROJECTS:+ }${POS[$idx]}"
  idx=$((idx + 1))
done
if [ "$NO_PROJECTS" -eq 1 ]; then
  [ -z "$CAPO_PROJECTS" ] || { echo "error: --no-projects cannot be combined with a project list" >&2; exit 1; }
else
  [ -n "$CAPO_PROJECTS" ] || { echo "error: --capo requires at least one project, or --no-projects for a project-less home" >&2; exit 1; }
fi
CAPO_CHARTER=${CS_CAPO_CHARTER:-"{TASK}"}
CAPO_SCOPE=${CS_CAPO_SCOPE:-${CS_CAPO_CHARTER:-"{TASK}"}}
if [ "$NO_PROJECTS" -eq 1 ]; then
  PROJECT_CLONES_BODY="None. This is a project-less domain: its subject is the consigliere repo this home lives in, so it needs no separate clones under \`projects/\`; its soldiers take worktrees of the same repo."
  PROJECT_CLONES_NOTE="This domain has no separate project clones: its subject is the consigliere repo this home lives in."
else
  PROJECT_CLONES_BODY=$(printf '%s\n' "$CAPO_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
  PROJECT_CLONES_NOTE="The projects above are local clones for work you supervise; they are not an exclusive ownership claim."
fi
cat > "$BRIEF" <<EOF
You are a persistent capo managed by the main consigliere. Work on your own; do not wait for a human.

# Charter
$CAPO_CHARTER

# Routing scope
$CAPO_SCOPE

# Project clones
$PROJECT_CLONES_BODY

# Operating model
You are in an isolated consigliere home. The local \`AGENTS.md\` is your job description, and your local \`config/\` (your user-owned tree), \`data/\`, \`state/\`, and \`projects/\` dirs are yours to operate.
$PROJECT_CLONES_NOTE
Delegate project work to your own soldiers with the normal consigliere lifecycle: brief, spawn, status, watcher, steer, teardown, and recovery.
Do not invent a second delegation system.
You do not generate your own work.
Act only on tasks the main consigliere routes to you.
Never start a survey, audit, or "find improvements" sweep on your own initiative; that is not your job and it is unwanted.

# Requests from the main consigliere
You are a consigliere in your own home, so an incoming message reaches you in your own chat.
You must distinguish who it is from, because the answer goes to a different place.
A request relayed to you by the main consigliere is tagged with a leading \`$CS_FROMCONS_LABEL\` marker followed by an invisible system separator; this marker is untypable, so a human never produces it.
When a message carries that marker, do the work, then respond via the STATUS/ESCALATION path below, never only in this chat: the main consigliere does not read your chat, so a chat-only reply is lost.
Marked requests also carry a privacy-safe \`corr=<id>\` token after the marker; include that exact token in your parent status reply (or in the status pointer to a detailed doc) so the parent can correlate the answer.
For a terse result, a status line is the whole answer.
For a detailed answer (an investigation, a plan, an audit), write it to a doc under your home's \`data/\` and append a status line that points to that doc so the main consigliere is woken and can read it.
Before treating an investigation or visual review as complete, load \`decision-hold-lifecycle\` from this home's \`skills/\` and pass its shared completion gate.
A message with NO marker is the boss typing directly into your pane: treat it as authoritative boss intervention and stay conversational exactly as you would for any boss message; do not force it onto the status path.

# Escalation to main consigliere
Handle routine work yourself.
Report only true boss-relevant outcomes or a declared external wait by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
Use \`$PAUSED_VERB: {why}\` (distinct from \`blocked:\`) only when your domain is deliberately idling on a known external wait you expect to clear on its own; use \`blocked:\` when you are stuck and need consigliere to act.
Use this only for material phase changes, a boss decision, a real blocker, a failure, or work ready for review.
This is also how you return the answer to a marked from-consigliere request above.
A marked request requires one correlated answer after the work; it does not require a separate receipt or start acknowledgement.
Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started.
When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above, give that reported phase a stable key.
If its first reportable event is \`working [key=<work-slug>]: {material phase}\`, use the same key on its later \`$PAUSED_VERB\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event so the earlier working phase is superseded.
When a keyed phase ends without another reportable state, append \`resolved [key=<work-slug>]: {why it is no longer active}\`.
\`resolved\` has a second, separate duty: it also closes an escalated decision or blocker, and only a \`resolved\` line carrying that decision's exact key closes it - a later \`done\` or \`working\` event never does, even when the answer is what started that work.
The main consigliere's answer normally writes that closing line at answer time; when a blocker or wait clears WITHOUT an answer from the main consigliere, append \`resolved: {how it cleared}\` yourself (keyed with \`[key=<slug>]\` if you opened it with one) as your domain resumes.
Routine internal supervision, heartbeats, retries, and soldier churn stay inside your own home and must not touch that status file.

# Definition of done
You are persistent by default. Do not exit just because your queue is empty.
On startup and restart, run normal consigliere bootstrap and recovery through \`bin/cs-session-start.sh\` for your own home, but only to RECONCILE work that is already yours: in-flight soldiers, tracked backlog items, and durable watches recorded in this home.
When you have no assigned or in-flight work after that reconciliation, go idle and wait silently for the main consigliere to route you a task.
An empty queue is a healthy resting state, not a cue to invent work: never spawn a survey, audit, or any self-directed "find work" task on your own initiative.
If this charter cannot be carried out, append \`blocked: {why}\` or \`failed: {why}\` to the main status file and stop.
EOF
if [ "$CAPO_CHARTER" = "{TASK}" ]; then
  echo "scaffolded: $BRIEF (capo charter; replace {TASK})"
else
  echo "scaffolded: $BRIEF (capo charter)"
fi
exit 0
fi

REPO=${POS[1]}

# Rule 6 continuation shared by the scout and ship briefs (the capo charter
# states its own variant, whose obligation differs: a capo must not route a boss
# message onto the parent status path at all).
# A relayed decision carries the untypable from-consigliere marker, so an
# unmarked message is the boss typing into the pane directly. The soldier is
# told to close the key anyway, because the keyed status fold in
# bin/cs-classify-lib.sh keeps a needs-decision OPEN until a matching resolved
# line lands: a boss answer given in the pane and never closed leaves the
# decision open in every home above this one, which re-escalates it and can draw
# a second, conflicting answer for the same gate.
# shellcheck disable=SC2016  # single quotes are deliberate: the backtick-wrapped `resolved:` must reach the reading agent verbatim, not expand at scaffold time
BOSS_INTERVENTION_RULE='   A decision relayed by consigliere carries an invisible from-consigliere marker. A message WITHOUT that marker is the boss typing directly into your pane: treat it as authoritative, answer conversationally as you would any boss message, and then still append the `resolved:` line above, because a decision the boss settles here stays open above you until you close it.'

if [ "$HERDR_LAB" -eq 1 ]; then
HERDR_LAB_HELPER=$(shell_quote "$CS_ROOT/bin/cs-herdr-lab.sh")
# shellcheck disable=SC2016  # single quotes are deliberate: these lines are literal brief text whose backtick-wrapped $(...) and "$HERDR_LAB_SESSION" snippets must reach the reading agent verbatim, not expand at scaffold time; only the '"$VAR"' break-outs interpolate.
HERDR_SECTION=$(printf '%s\n' \
'# Herdr isolation - HARD SAFETY CONTRACT' \
'This brief was explicitly scaffolded with `--herdr-lab` because the task will drive herdr lifecycle behavior.' \
'The API socket is not relocatable by environment overrides; a named non-`default` session plus a trailing `--session <name>` on every call is the only viable local isolation.' \
'' \
'1. Set `HERDR_LAB_HELPER='"$HERDR_LAB_HELPER"'` and generate the session name with `HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name '"$ID"')`.' \
'   Install `trap '\''"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"'\'' EXIT` before provisioning, then provision only with `"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"`.' \
'2. Run every task-specific non-lifecycle herdr command through `"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" <arguments...>`.' \
'   The helper appends the required trailing `--session "$HERDR_LAB_SESSION"`; `HERDR_SESSION` alone is never accepted as isolation.' \
'3. Teardown only through `"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"`.' \
'   It re-checks refuse-default immediately before stop and again immediately before delete, and fails closed on ambiguity.' \
'4. If an experiment requires a deliberate mid-run session stop, use only `"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION"`; it performs the same immediate refuse-default check.' \
'5. Forbidden commands: direct `herdr server stop`, every other server-global operation, direct `herdr session stop`, direct `herdr session delete`, and any herdr call scoped only by ambient or inline `HERDR_SESSION`.' \
'6. The helper records the live default session before provisioning and verifies the identical fleet state after teardown.' \
'   A missing, stopped, or changed default session is a hard tripwire failure, never a cleanup warning to ignore.' \
'' \
'Never bypass the helper, even for a read-only lifecycle probe or cleanup after failure.' \
'The boss fleet uses the running `default` session.')
else
IFS= read -r -d '' HERDR_SECTION <<'EOF' || true
# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text that replaces `{TASK}` later.
If the task will start, stop, delete, restart, profile, or otherwise drive herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add herdr lifecycle commands to this unguarded brief by hand.
EOF
HERDR_SECTION=${HERDR_SECTION%$'\n'}
fi

if [ "$KIND" = scout ]; then
cat > "$BRIEF" <<EOF
You are a soldier: an autonomous worker agent managed by consigliere. Work on your own; do not wait for a human.

# Task
{TASK}

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO on the task branch \`cs/$ID\`.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.

# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes consigliere, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/paused/done/failed states. No step-by-step
   FYI progress lines; consigliere reads your pane for that.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset):
   consigliere then leaves your idle pane alone and rechecks it on a long cadence instead of
   treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; consigliere will help.
6. If a decision belongs to a human (product choices, destructive actions),
   append \`needs-decision: {summary of options}\` and stop. Consigliere will reply with the decision.
   A decision or blocker you opened stays open until a \`resolved\` line carrying its exact key lands; a later \`done:\` or \`working:\` line never closes it, even when the answer is what started that work.
   Consigliere's reply normally writes that closing line at answer time; when a blocker or wait clears WITHOUT a reply from consigliere, append \`resolved: {how it cleared}\` yourself (add the same \`[key=<slug>]\` if you opened it with one) as you resume.
$BOSS_INTERVENTION_RULE
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only consigliere manages the daemon.

# Definition of done
Write your findings to \`$DATA/$ID/report.md\`.
The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
Before reporting done, read and follow \`$CS_ROOT/skills/decision-hold-lifecycle/SKILL.md\` and pass its shared completion gate for the report and any visual review.
When the report is complete, append \`done: {one-line conclusion}\` to the status file and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; consigliere may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
EOF
echo "scaffolded: $BRIEF (scout; replace {TASK})"
exit 0
fi

# Ship task: shape Setup / Rule 1 / Definition of done by the explicit --mode,
# already validated against the closed set above.
case "$MODE" in
  direct-PR)
    SETUP2=""
    RULE1='1. Never push to the default branch (push only your `cs/'"$ID"'` branch). Never merge a PR.'
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; consigliere relays the outcome.
EOF
    ;;
  local-only)
    SETUP2=""
    RULE1="1. Never push to any remote and never open a PR. Work only on your \`cs/$ID\` branch; consigliere handles the merge into local \`main\`."
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`cs/$ID\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch cs/$ID\` to the status file and stop.
The configured merge authority approves the ready branch, then consigliere merges it into local \`main\` through the guarded fast-forward path.
EOF
    ;;
  *)  # no-mistakes; the closed-set validation above admits nothing else
    SETUP2="
2. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
    RULE1='1. Never push to the default branch. Never merge a PR.'
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
The task is complete only when committed on your branch.
When you believe it is complete, append \`needs-review: {summary of what you built}\` to the status file and stop.
Use \`needs-review:\` here, NOT \`done:\` - this mode adds that one state to the list in rule 4.
Consigliere reviews your commit against the task, then instructs you to run \$no-mistakes to validate and ship a PR.
\`needs-review:\` stays open above you until consigliere acts on it, so an unreviewed commit cannot be mistaken for finished work; \`done:\` would read as complete and could sit unnoticed.
When consigliere tells you to validate, append \`resolved: {how it was reviewed or unblocked}\` (carrying the same \`[key=<slug>]\` if you opened one) before you start the run.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke \$no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When you start the run, make \`--intent\` preserve all relevant content from this brief's \`# Task\` section plus every later accepted consigliere requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain the direct requirements instead of substituting a summary of your diff, and leave out generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two consigliere-specific rules layer on top of that guidance:
- ask-user findings are not yours to answer: escalate to consigliere (rule 6) and stop.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid \`--yes\`: the boss, not you, owns the ask-user decisions it would silently auto-resolve.

After \$no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.
In this mode \`done:\` means exactly that green-PR state and nothing else.
EOF
    ;;
esac

# read -r -d '' preserves the heredoc's trailing newline that a $(...) command
# substitution would have stripped. Drop that one newline so generated briefs
# keep their exact prior shape.
DOD=${DOD%$'\n'}

# The machine-readable contract cs-spawn.sh cross-checks its own --mode against.
# It is emitted last, after every section a caller rewrites while filling in
# {TASK}, so an edited brief cannot lose or contradict it by accident.
CONTRACT_LINE=$(cs_delivery_contract_line "$MODE")

if [ -n "$ISSUE" ]; then
  if [ "$MODE" = local-only ]; then
    IFS= read -r -d '' ISSUE_SECTION <<EOF || true
# Board issue #$ISSUE
This task implements GitHub issue #$ISSUE.
This task ships local-only (no PR), so you cannot close the issue with a PR keyword.
Do the work as usual; consigliere closes issue #$ISSUE after it lands the approved local merge.
Do NOT close the issue yourself and do NOT move its board card - the board's own workflow handles the card once the issue is closed.
EOF
  elif [ "$MODE" = no-mistakes ]; then
    IFS= read -r -d '' ISSUE_SECTION <<EOF || true
# Board issue #$ISSUE - THE PR MUST CLOSE IT
This task implements GitHub issue #$ISSUE.
The merged PR MUST close this issue via the GitHub closing keyword \`Closes #$ISSUE\`, so that the board's built-in workflow moves its card to Done. This is a hard requirement, not a nicety: if the PR does not close the issue, the card is stranded in In Progress.
You do NOT open the PR - the no-mistakes pipeline owns push and PR creation. So do not try to create or find a PR to satisfy this; instead route the closing keyword into the material the pipeline builds the PR from:
- Put the line \`Closes #$ISSUE\` in your commit message body before you run no-mistakes.
- Include "This PR closes #$ISSUE." in the \`--intent\` you pass to \`no-mistakes axi run\`, so the pipeline's PR step writes the closing keyword into the PR description.
Do NOT edit the project board yourself and do NOT close the issue by hand - the merge does both through \`Closes #$ISSUE\`.
EOF
  else
    IFS= read -r -d '' ISSUE_SECTION <<EOF || true
# Board issue #$ISSUE - PR MUST CLOSE IT
This task implements GitHub issue #$ISSUE.
The PR description you open MUST contain the line \`Closes #$ISSUE\` (a GitHub closing keyword) so that merging the PR closes the issue and the board's built-in workflow moves its card to Done.
This is a hard requirement, not a nicety: if the PR does not close the issue, the card is stranded in In Progress.
Do NOT edit the project board yourself and do NOT close the issue by hand - the merge does both through \`Closes #$ISSUE\`.
EOF
  fi
  ISSUE_SECTION=${ISSUE_SECTION%$'\n'}
else
  ISSUE_SECTION=""
fi

cat > "$BRIEF" <<EOF
You are a soldier: an autonomous worker agent managed by consigliere. Work on your own; do not wait for a human.

# Task
{TASK}
$ISSUE_SECTION

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO on the task branch \`cs/$ID\`, created for you at spawn.

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in (a linked worktree under \`~/.herdr/worktrees/\`), not the primary checkout consigliere operates from.
Also verify \`git branch --show-current\` prints \`cs/$ID\`.
The path check is authoritative: \`git rev-parse --git-dir\` and \`git rev-parse --git-common-dir\` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout, not the worktree you were launched in, or the branch is wrong, STOP - do not commit here - append \`blocked: launched outside the isolated task worktree\` to the status file and stop.$SETUP2

# Rules
$RULE1
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes consigliere, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
   consigliere reads your pane for that.
   A mid-task \`working:\` line (including setup complete) is nonterminal: do not end the
   turn after it; continue the same stage until a defined \`done:\` gate under Definition of done.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset,
   a scheduled window): consigliere then leaves your idle pane alone and rechecks it on a long
   cadence instead of treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; consigliere will help.
6. If a decision belongs to a human (product choices, destructive actions, ask-user findings),
   append \`needs-decision: {summary of options}\` and stop. Consigliere will reply with the decision.
   A decision or blocker you opened stays open until a \`resolved\` line carrying its exact key lands; a later \`done:\` or \`working:\` line never closes it, even when the answer is what started that work.
   Consigliere's reply normally writes that closing line at answer time; when a blocker or wait clears WITHOUT a reply from consigliere, append \`resolved: {how it cleared}\` yourself (add the same \`[key=<slug>]\` if you opened it with one) as you resume.
$BOSS_INTERVENTION_RULE
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only consigliere manages the daemon.

# Project memory
If \`AGENTS.md\` or \`CLAUDE.md\` already exists, or if this task produced durable project-intrinsic knowledge, run \`$CS_ROOT/bin/cs-ensure-agents-md.sh .\` in the worktree.
Record only project knowledge useful to almost every future session.
For anything the codebase already shows, prefer a pointer to the authoritative file, command, or doc over copying the detail.
If you touch a project \`AGENTS.md\` that lacks \`## Maintaining this file\`, add that short self-governance section from \`$CS_ROOT/bin/cs-ensure-agents-md.sh\` in the same pass.
Keep it proportionate: skip \`AGENTS.md\` edits for trivial tasks that produced no durable project knowledge.

$DOD

$CONTRACT_LINE
EOF
echo "scaffolded: $BRIEF (ship, mode=$MODE; replace {TASK})"
