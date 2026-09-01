#!/usr/bin/env bash
# Behavior: cs-inherit-lib.sh convergence discipline for the tiny capo
# inheritance surface. The main copy is authoritative: a capo copy is
# rewritten only when it no longer matches what the main copy renders to,
# never churned when converged, quarantined (never destroyed) when it
# diverged, and nothing ever flows back into the main home.
set -u
# shellcheck source=tests/capo-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/capo-helpers.sh"
# shellcheck source=bin/cs-inherit-lib.sh
. "$ROOT/bin/cs-inherit-lib.sh"

TMP=$(cs_test_tmproot cs-inherit)
mkdir -p "$TMP"

MAIN="$TMP/main"
CAPO="$TMP/capo"
mkdir -p "$MAIN/data" "$MAIN/config" "$CAPO/data" "$CAPO/config"
printf 'prefer squash merges\n' > "$MAIN/config/boss-shared.md"
printf 'manual\n' > "$MAIN/config/backlog-backend.conf"

DEST="$CAPO/config/boss-shared.md"

file_mtime() {
  if [ "$(uname -s)" = Darwin ]; then
    stat -f %m "$1"
  else
    stat -c %Y "$1"
  fi
}

# 1. seed-time propagation: header + content, read-only, backend copied
out=$(cs_inherit_seed "$MAIN" "$CAPO" 2>&1) || fail "seed inheritance failed: $out"
[ -z "$out" ] || fail "clean seed propagation must be silent, got: $out"
assert_grep 'DO NOT EDIT' "$DEST" "capo copy carries the do-not-edit header"
assert_grep 'prefer squash merges' "$DEST" "capo copy carries the main content"
[ ! -w "$DEST" ] || fail "capo copy must be read-only (mode 444)"
[ "$(cat "$CAPO/config/backlog-backend.conf")" = manual ] || fail "backlog-backend copied at seed"
pass "seed propagation writes a read-only headered copy plus the backend"

# 2. converged re-run is a byte-level no-op
before=$(shasum -a 256 "$DEST" | awk '{print $1}')
mtime_before=$(file_mtime "$DEST")
sleep 1
out=$(cs_inherit_converge "$MAIN" "$CAPO" 2>&1) || fail "converged re-run failed: $out"
[ -z "$out" ] || fail "converged re-run must be silent, got: $out"
after=$(shasum -a 256 "$DEST" | awk '{print $1}')
mtime_after=$(file_mtime "$DEST")
[ "$before" = "$after" ] || fail "converged re-run must not change bytes"
[ "$mtime_before" = "$mtime_after" ] || fail "converged re-run must not churn mtime"
[ ! -w "$DEST" ] || fail "converged re-run must keep the copy read-only"
pass "an unchanged main copy never rewrites the capo copy"

# 3. main change converges the capo copy (old bytes preserved in quarantine)
printf 'prefer squash merges\nnever rebase published\n' > "$MAIN/config/boss-shared.md"
out=$(cs_inherit_converge "$MAIN" "$CAPO" 2>&1) || fail "main-change convergence failed: $out"
assert_contains "$out" "CAPO_SYNC:" "replacement of stale bytes is reported"
assert_grep 'never rebase published' "$DEST" "capo copy follows the main change"
pass "a changed main copy converges the capo copy"

# 4. capo-local drift is quarantined and overwritten, never pushed back
chmod u+w "$DEST"
printf 'rogue local edit\n' >> "$DEST"
main_before=$(shasum -a 256 "$MAIN/config/boss-shared.md" | awk '{print $1}')
out=$(cs_inherit_converge "$MAIN" "$CAPO" 2>&1) || fail "drift convergence failed: $out"
assert_contains "$out" "quarantined config/boss-shared.md drift" "drift is reported as CAPO_SYNC"
assert_no_grep 'rogue local edit' "$DEST" "drifted bytes are replaced by the main copy"
quarantine=$(printf '%s\n' "$out" | sed -n 's/.* drift at \(.*\)$/\1/p' | head -1)
[ -n "$quarantine" ] && [ -f "$quarantine" ] || fail "quarantine artifact must exist"
assert_grep 'rogue local edit' "$quarantine" "quarantine preserves the drifted bytes"
main_after=$(shasum -a 256 "$MAIN/config/boss-shared.md" | awk '{print $1}')
[ "$main_before" = "$main_after" ] || fail "capo drift must NEVER flow back into the main copy"
pass "capo drift is quarantined and overwritten, never pushed back"

# 5. main absence converges by quarantining the capo copy
rm "$MAIN/config/boss-shared.md"
out=$(cs_inherit_converge "$MAIN" "$CAPO" 2>&1) || fail "absence convergence failed: $out"
assert_contains "$out" "main copy absent" "absence mirroring is reported"
assert_absent "$DEST" "capo copy removed when the main copy is absent"
out=$(cs_inherit_converge "$MAIN" "$CAPO" 2>&1) || fail "second absence convergence failed: $out"
[ -z "$out" ] || fail "absent-absent convergence must be silent, got: $out"
pass "main absence converges downstream (idempotently)"

# 6. symlinked destination refuses instead of following it
printf 'shared again\n' > "$MAIN/config/boss-shared.md"
ln -s /etc/hosts "$DEST"
out=$(cs_inherit_converge "$MAIN" "$CAPO" 2>&1) && fail "symlinked destination must refuse"
assert_contains "$out" "unsafe destination" "symlink refusal names the reason"
rm "$DEST"
pass "a symlinked capo copy refuses propagation"

# 7. a symlinked MAIN SOURCE is read through: propagation is a read, and a home
#    may keep the authoritative file under external configuration management.
printf 'shared from dotfiles\n' > "$TMP/external-boss-shared.md"
rm -f "$MAIN/config/boss-shared.md"
ln -s "$TMP/external-boss-shared.md" "$MAIN/config/boss-shared.md"
out=$(cs_inherit_converge "$MAIN" "$CAPO" 2>&1) || fail "symlinked main source must propagate: $out"
assert_grep 'shared from dotfiles' "$DEST" "capo copy carries the symlinked source content"
assert_grep 'DO NOT EDIT' "$DEST" "symlinked source still renders the do-not-edit header"
[ ! -L "$DEST" ] || fail "destination must be a real file, never a link back to the source"
pass "a symlinked main source resolving to a regular file is propagated"

# 8. an unresolved main-source symlink stops propagation instead of mirroring
#    absence: a broken link is a broken configuration, not a deliberate removal.
rm -f "$MAIN/config/boss-shared.md"
ln -s "$TMP/no-such-boss-shared.md" "$MAIN/config/boss-shared.md"
out=$(cs_inherit_converge "$MAIN" "$CAPO" 2>&1) && fail "an unresolved main source must refuse"
assert_contains "$out" "unusable main source" "unresolved source refusal names the reason"
assert_grep 'shared from dotfiles' "$DEST" "a refused run leaves the capo copy untouched"
rm -f "$MAIN/config/boss-shared.md"
printf 'shared again\n' > "$MAIN/config/boss-shared.md"
pass "an unresolved main-source symlink blocks propagation"

# 9. backlog-backend: seed copy converges value and mirrors absence
printf 'tasks-axi\n' > "$MAIN/config/backlog-backend.conf"
cs_inherit_backlog_backend "$MAIN/config" "$CAPO/config" || fail "backend copy failed"
[ "$(cat "$CAPO/config/backlog-backend.conf")" = tasks-axi ] || fail "backend value must converge at seed"
rm "$MAIN/config/backlog-backend.conf"
cs_inherit_backlog_backend "$MAIN/config" "$CAPO/config" || fail "backend absence mirror failed"
assert_absent "$CAPO/config/backlog-backend.conf" "backend absence mirrored at seed"
pass "backlog-backend seed copy converges value and absence"

pass "cs-inherit convergence discipline"
