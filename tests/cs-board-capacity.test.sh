#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(cs_test_tmproot cs-board-capacity)
HOME_DIR="$TMP_ROOT/home"
PROJECT="$HOME_DIR/projects/proj"
PROJECT_ABS=
STATE="$HOME_DIR/state"
ORPHAN="$TMP_ROOT/orphaned-task"
FAKEBIN=$(cs_fakebin "$TMP_ROOT")
BIN="$ROOT/bin/cs-board-capacity.sh"

mkdir -p "$HOME_DIR/data" "$STATE" "$PROJECT" "$ORPHAN"
git -C "$PROJECT" init -q
PROJECT_ABS=$(cd "$PROJECT" && pwd -P)
printf 'do not remove\n' > "$ORPHAN/keep.txt"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "pane get")
    case " ${CS_FAKE_LIVE_PANES:-} " in
      *" ${3:-} ") printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$3"; exit 0 ;;
      *) printf '{"error":{"code":"pane_not_found"}}\n'; exit 0 ;;
    esac
    ;;
  "status --json") printf '{"server":{"protocol":16}}\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = api ] && [ "${2:-}" = /repos/o/r/pulls/303 ]; then
  printf '%s\n' '2026-08-05T12:00:00Z'
  exit 0
fi
exit 1
SH
chmod +x "$FAKEBIN/gh-axi"

cat > "$HOME_DIR/data/backlog.md" <<'MD'
## In flight

- [ ] live-a - first live task
- [ ] live-b - second live task
- [ ] merged-orphan - merged task awaiting cleanup

## Queued

- [ ] ready-c - replacement work
MD
backlog_before=$(shasum -a 256 "$HOME_DIR/data/backlog.md")

cs_write_meta "$STATE/live-a.meta" \
  "pane=live-a" "worktree=$TMP_ROOT/live-a" "project=$PROJECT_ABS" "kind=ship"
cs_write_meta "$STATE/live-b.meta" \
  "pane=live-b" "worktree=$TMP_ROOT/live-b" "project=$PROJECT_ABS" "kind=ship"
cs_write_meta "$STATE/merged-orphan.meta" \
  "pane=" "worktree=$ORPHAN" "project=$PROJECT_ABS" "kind=ship" \
  "pr=https://github.com/o/r/pull/303"

out=$(env PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" \
  CS_FAKE_LIVE_PANES='live-a live-b' "$BIN" proj 3) \
  || fail "capacity owner failed: $out"
assert_contains "$out" 'occupied=2' "two live task endpoints occupy two lanes"
assert_contains "$out" 'free=1' "merged orphan releases one dispatch lane"
assert_contains "$out" 'cleanup_pending=1' "merged orphan remains durable cleanup follow-up"

leading_zero_out=$(env PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" \
  CS_FAKE_LIVE_PANES='live-a live-b' "$BIN" proj 08) \
  || fail "capacity owner rejected a leading-zero cap: $leading_zero_out"
assert_contains "$leading_zero_out" 'cap=8' "leading-zero cap is normalized as decimal"
assert_contains "$leading_zero_out" 'free=6' "leading-zero cap keeps decimal lane semantics"

[ -d "$ORPHAN" ] || fail "capacity accounting removed the orphan directory"
assert_present "$ORPHAN/keep.txt" "capacity accounting modified the orphan directory"
assert_absent "$ORPHAN/.git" "orphan fixture unexpectedly gained a git marker"
if git -C "$PROJECT" worktree list --porcelain | grep -F "$ORPHAN" >/dev/null; then
  fail "orphan fixture was registered as a git worktree"
fi

backlog_after=$(shasum -a 256 "$HOME_DIR/data/backlog.md")
[ "$backlog_before" = "$backlog_after" ] || fail "capacity accounting modified the stale backlog"
pass "capacity owner frees one lane for a merged unregistered orphan without touching cleanup"
