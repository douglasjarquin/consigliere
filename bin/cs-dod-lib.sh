#!/usr/bin/env bash
# Single owner of a ship task's mode-specific "Definition of done" text,
# including the ask-user escalation rule and the --yes prohibition.
# Sourced by bin/cs-brief.sh (ship scaffolds) and bin/cs-promote.sh (promotion
# ship instructions) so a briefed worker and a promoted scout receive the
# byte-identical contract and the two scripts cannot drift apart.
# Requires cs_resolve_root to have run first: the rendered text bakes in the
# resolved $CS_HOME, $CS_ROOT, $STATE, and $DATA paths.
# cs_dod_render <mode> <task-id> prints the block for one already-validated
# delivery mode (bin/cs-delivery-lib.sh owns the closed set); an out-of-set
# mode is a hard failure, never a silent default.

# Shared by direct-PR and made only (local-only never opens a PR, so it
# is out of this section's scope): the render-then-commit recipe for any
# bossless-mode auto-decision recorded against this task, per
# bin/cs-auto-decision-lib.sh's SCHEMA-OWNER header. The ledger lives in THIS
# consigliere home's own data/, not the target project, so CS_HOME/CS_ROOT are
# baked in now as concrete absolute paths rather than left for the worker to
# resolve inside a different worktree. Sourcing the library pulls in
# cs-afk-start.sh, which unconditionally calls cs_resolve_root - a live
# reproduction proved that recomputes STATE/DATA from CS_STATE_OVERRIDE/
# CS_DATA_OVERRIDE (or CS_HOME), silently stomping a plain STATE=/DATA=
# assignment, so the override names are the only ones that actually stick.
cs_dod_render() {
  local mode=$1 id=$2 auto=""

  case "$mode" in
    made|direct-PR)
      IFS= read -r -d '' auto <<EOF || true
If any ask-user finding during this task was auto-decided under bossless mode, its record lives in this consigliere home's own ledger, not yet in this project. Render and commit it before you finish, as an ordinary part of your diff:
\`\`\`
CS_HOME=$CS_HOME CS_STATE_OVERRIDE=$STATE CS_DATA_OVERRIDE=$DATA bash -c ". $CS_ROOT/bin/cs-auto-decision-lib.sh && cs_auto_decision_render $id" > /tmp/auto-decisions-$id.md
if [ -s /tmp/auto-decisions-$id.md ]; then mkdir -p docs/auto-decisions && mv /tmp/auto-decisions-$id.md docs/auto-decisions/$id.md && git add docs/auto-decisions/$id.md; fi
\`\`\`
Skip this entirely when the temp file ends up empty (no bossless decisions occurred) - never commit an empty file, and never touch the ledger itself.
EOF
      auto=${auto%$'\n'}
      ;;
  esac

  case "$mode" in
    direct-PR)
      cat <<EOF
# Definition of done
This task ships **direct-PR**: you raise the PR yourself, without the made pipeline.
The task is complete only when committed on your branch.

$auto
When docs/auto-decisions/$id.md exists, include this short section in the PR body you write yourself, with its path as a real repo-relative link:
\`\`\`
## Auto-decisions (bossless mode)
See \`docs/auto-decisions/$id.md\` in this diff.
\`\`\`

When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /made. The configured merge authority decides whether to merge the PR; consigliere relays the outcome.
EOF
      ;;
    local-only)
      cat <<EOF
# Definition of done
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`cs/$id\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch cs/$id\` to the status file and stop.
The configured merge authority approves the ready branch, then consigliere merges it into local \`main\` through the guarded fast-forward path.
EOF
      ;;
    made)
      cat <<EOF
# Definition of done
The task is complete only when committed on your branch.
When you believe it is complete, append \`needs-review: {summary of what you built}\` to the status file and stop.
Use \`needs-review:\` here, NOT \`done:\` - this mode adds that one state to the list in rule 4.
Consigliere reviews your commit against the task, then instructs you to run \$made to validate and ship a PR.
\`needs-review:\` stays open above you until consigliere acts on it, so an unreviewed commit cannot be mistaken for finished work; \`done:\` would read as complete and could sit unnoticed.
When consigliere tells you to validate, append \`resolved: {how it was reviewed or unblocked}\` (carrying the same \`[key=<slug>]\` if you opened one) before you start the run.

$auto
If docs/auto-decisions/$id.md exists, append one more sentence to the same \`--intent\` text below: "N ask-user findings were auto-decided under bossless mode; see \`docs/auto-decisions/$id.md\` in this diff." (fill in N with \`grep -c '^- \\*\\*\\[' docs/auto-decisions/$id.md\`). Never call \`gh-axi pr edit\` or any other direct PR-mutation command to add this yourself - made owns the PR object end to end in this mode, and the committed file, not this sentence, is the durable evidence.

You drive made by responding to its gates, not by implementing fixes.
Follow the guidance made itself provides for the mechanics: it loads when you invoke \$made, and \`made doctor\` plus \`made status --json\` are authoritative and version-matched to the installed binary.
When you start the run, make \`--intent\` preserve all relevant content from this brief's \`# Task\` section plus every later accepted consigliere requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain the direct requirements instead of substituting a summary of your diff, and leave out generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two consigliere-specific rules layer on top of that guidance:
- ask-user findings are not yours to answer: append \`needs-decision: {summary of options}\` to the status file and stop. Consigliere replies with the decision.
  When the decision comes back, feed it to the gate with \`made review\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Never pass \`--yes\`: the boss, not you, owns the ask-user decisions it would silently auto-resolve.

After \$made reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.
In this mode \`done:\` means exactly that green-PR state and nothing else.
EOF
      ;;
    *)
      echo "error: cs_dod_render: unknown delivery mode '$mode'" >&2
      return 1
      ;;
  esac
}
