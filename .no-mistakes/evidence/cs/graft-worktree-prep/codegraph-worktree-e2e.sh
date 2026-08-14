#!/usr/bin/env bash
# End-to-end demonstration of the codegraph worktree-index feature, using the
# REAL codegraph binary (1.5.0) and a REAL git worktree. Only herdr is faked,
# because a live terminal multiplexer pane is not part of what is being shown.
#
# 1. baseline: a fresh git worktree inherits no codegraph index (the problem)
# 2. cs-spawn.sh spawn: spawn_codegraph_prep builds a real index in the worktree
# 3. the built index actually answers a codegraph query from the worktree
# 4. CS_SPAWN_CODEGRAPH_PREP=off: kill switch leaves the worktree unindexed
set -u

ROOT=${ROOT:?set ROOT to the consigliere worktree}
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/cg-e2e.XXXXXX")
trap 'chmod -R u+rwX "$SCRATCH" 2>/dev/null; rm -rf "$SCRATCH"' EXIT

say() { printf '\n=== %s ===\n' "$*"; }

# --- a realistic primary checkout with indexable source ---------------------
PROJ="$SCRATCH/proj"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
cat > "$PROJ/orders.py" <<'PY'
def compute_total(items):
    return sum(price_of(i) for i in items)


def price_of(item):
    return item["qty"] * item["unit_price"]


def checkout(cart):
    return {"total": compute_total(cart["items"])}
PY
cat > "$PROJ/report.py" <<'PY'
from orders import compute_total


def daily_report(carts):
    return [compute_total(c["items"]) for c in carts]
PY
printf '.codegraph\n' > "$PROJ/.gitignore"
git -C "$PROJ" add -A
git -C "$PROJ" -c user.name=Tests -c user.email=t@example.invalid -c commit.gpgsign=false \
  commit -qm "orders fixture"

say "primary checkout: build its codegraph index (what a real project has)"
codegraph init "$PROJ" 2>&1 | sed 's/^/  /'
printf '  primary index file: '
[ -f "$PROJ/.codegraph/codegraph.db" ] && echo "$PROJ/.codegraph/codegraph.db" || echo MISSING

# --- 1. baseline: a plain worktree inherits nothing --------------------------
say "BASELINE: plain \`git worktree add\` - the problem this feature exists for"
git -C "$PROJ" worktree add -q -b baseline "$SCRATCH/wt-baseline"
if [ -e "$SCRATCH/wt-baseline/.codegraph" ]; then
  echo "  worktree HAS an index (unexpected)"
else
  echo "  worktree has NO .codegraph at all - the soldier's first turn is index-less"
fi
echo "  a query from that worktree:"
(cd "$SCRATCH/wt-baseline" && codegraph query compute_total 2>&1 | head -4 | sed 's/^/    /')

# --- fake herdr: real `git worktree add`, always-present agent ---------------
FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "status --json") printf '%s\n' '{"server":{"protocol":16}}' ;;
  "worktree create")
    repo= branch= base=
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --cwd) repo=$2; shift ;;
        --branch) branch=$2; shift ;;
        --base) base=$2; shift ;;
      esac
      shift
    done
    if [ -n "$base" ]; then
      git -C "$repo" worktree add -q -b "$branch" "$CS_FAKE_SPAWN_WORKTREE" "$base"
    else
      git -C "$repo" worktree add -q -b "$branch" "$CS_FAKE_SPAWN_WORKTREE"
    fi
    printf '{"result":{"workspace":{"workspace_id":"w1"},"root_pane":{"pane_id":"w1:p1"},"worktree":{"path":"%s","branch":"%s"}}}\n' "$CS_FAKE_SPAWN_WORKTREE" "$branch"
    ;;
  "pane run") printf '%s' "${4:-}" > "$CS_FAKE_SPAWN_LAUNCH" ;;
  "agent get") printf '{"result":{"agent":{"agent":"codex","agent_status":"idle"}}}\n' ;;
  *) printf '{}\n' ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

HOME_DIR="$SCRATCH/cs-home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state"

spawn() {  # <task-id> [extra env K=V ...]
  local id=$1; shift
  mkdir -p "$HOME_DIR/data/$id"
  printf 'index the orders module\nDelivery contract: mode=made\n' > "$HOME_DIR/data/$id/brief.md"
  env PATH="$FAKEBIN:$PATH" CS_HARNESS_OVERRIDE=codex \
    CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$HOME_DIR/state" \
    CS_SPAWN_LAUNCH_WAIT_SECS=5 \
    CS_FAKE_SPAWN_WORKTREE="$SCRATCH/wt-$id" CS_FAKE_SPAWN_LAUNCH="$SCRATCH/launch-$id" \
    "$@" \
    "$ROOT/bin/cs-spawn.sh" "$id" "$PROJ" --mode made --yolo off 2>&1
}

# --- 2. the spawn a boss actually runs --------------------------------------
say "SPAWN: bin/cs-spawn.sh t-index <project> --mode made (real codegraph on PATH)"
spawn t-index | sed 's/^/  /'
say "the spawned worktree, right after the spawn"
ls -a "$SCRATCH/wt-t-index/.codegraph" 2>&1 | sed 's/^/  /'
(cd "$SCRATCH/wt-t-index" && codegraph status 2>&1 | head -12 | sed 's/^/  /')

# --- 3. the index is usable from the worktree -------------------------------
say "the soldier's first turn can query its own worktree index"
(cd "$SCRATCH/wt-t-index" && codegraph callers compute_total 2>&1 | head -20 | sed 's/^/  /')

# --- 4. kill switch ---------------------------------------------------------
say "KILL SWITCH: CS_SPAWN_CODEGRAPH_PREP=off"
spawn t-off CS_SPAWN_CODEGRAPH_PREP=off | sed 's/^/  /'
if [ -e "$SCRATCH/wt-t-off/.codegraph" ]; then
  echo "  worktree HAS an index (kill switch FAILED)"
else
  echo "  worktree has no .codegraph - prep did not run, spawn still completed"
fi
printf '  launch line delivered to the pane: '
head -c 120 "$SCRATCH/launch-t-off"; echo

say "DONE"
