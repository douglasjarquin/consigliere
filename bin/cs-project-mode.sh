#!/usr/bin/env bash
# Report a project's STANDING delivery posture: the mode and yolo flag the boss
# recorded for it in the config/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# made|direct-PR|local-only and yolo is on|off.
#
# This is a registry reporter, not the resolver of any task's delivery posture. A
# ship task's mode and yolo are decided per task at intake and passed explicitly
# to cs-brief.sh, cs-spawn.sh, and cs-promote.sh; bin/cs-delivery-lib.sh owns that
# vocabulary. The standing posture is advisory: cs-spawn.sh notes a task that
# deviates downward from it and continues.
# Callers here hold no task and want exactly the registry's own answer:
# cs-fleet-sync.sh (skip local-only clones) and cs-home-seed.sh (capo route
# eligibility and made initialization).
#
# Registry line format (config/projects.md):
#   - <name> - <desc> (added <date>)                  -> made off  (default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#
# mode = how a finished change reaches main:
#   made         full pipeline -> PR -> boss merge (default)
#   direct-PR    push + PR via gh-axi, no pipeline -> boss merge
#   local-only   local branch, no remote/PR -> boss approve -> guarded local merge
# yolo (orthogonal) = when on, consigliere answers routine gate decisions itself
#   (ask-user findings within the accepted task contract) instead of waiting on
#   the boss. It never authorizes landing: a PR merge and a local-only merge are
#   the boss's alone, yolo or not. Anything destructive, irreversible, or
#   security-sensitive still escalates, and so does a fix that would materially
#   expand the product or engineering contract. AGENTS.md section 7 is the owner.
#
# An unknown/missing project or unknown mode falls back to "made off" and
# warns to stderr, so a typo never silently drops the gate.
#
# --standing asks the narrower question "does this project have a standing posture
# at all?", for a caller that must distinguish an unregistered project from a
# registered one carrying the default. It prints the same "<mode> <yolo>" and
# exits 0 for a registered project, and exits 3 printing nothing - and warning
# nothing - when there is no registry or no entry. An unregistered project simply
# has no standing posture; that is not a fault to report.
# Usage: cs-project-mode.sh [--standing] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
REG="$CONFIG/projects.md"
STANDING_ONLY=0
if [ "${1:-}" = --standing ]; then
  STANDING_ONLY=1
  shift
fi
NAME=${1:?usage: cs-project-mode.sh [--standing] <project-name>}

if [ ! -f "$REG" ]; then
  [ "$STANDING_ONLY" -eq 1 ] && exit 3
  echo "warn: no registry at $REG; defaulting $NAME to made off" >&2
  echo "made off"
  exit 0
fi

# awk emits "<mode> <yolo>" (one line) or nothing if the project is absent.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="made"; yolo="off";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "" && a[1] != "+yolo") mode = a[1];
      for (j=1; j<=k; j++) if (a[j]=="+yolo") yolo="on";
    }
    print mode, yolo; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  [ "$STANDING_ONLY" -eq 1 ] && exit 3
  echo "warn: project \"$NAME\" not in registry; defaulting to made off" >&2
  echo "made off"
  exit 0
fi

mode=${parsed%% *}
yolo=${parsed##* }
case "$mode" in
  made|direct-PR|local-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to made off" >&2; mode=made; yolo=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
echo "$mode $yolo"
