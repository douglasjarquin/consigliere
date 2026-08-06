#!/usr/bin/env bash
# Behavior: cs-home-seed.sh transactional capo home provisioning and the
# bootstrap sweep. Covers: happy-path seed (detached worktree home, marker,
# registry round-trip, charter copy, project clone, seed-time inheritance),
# idempotent re-seed, registry validation, TRANSACTIONAL ROLLBACK on a forced
# mid-seed failure, mutual-exclusion and missing-charter refusals, the FF-only
# detached-HEAD sync sweep (updated / silent-current / dirty-skip), and the
# liveness sweep (respawn on confident dead only; inconclusive is skipped).
# Hermetic: the "consigliere repo" is a fixture; herdr and the respawn helper
# are faked; nothing touches the real checkout or a real server.
set -u
# shellcheck source=tests/capo-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/capo-helpers.sh"

TMP=$(cs_test_tmproot cs-home-seed)
mkdir -p "$TMP"
TMP=$(cd "$TMP" && pwd -P)  # macOS mktemp returns /var/...; scripts canonicalize to /private/var
cs_git_identity

MAIN="$TMP/mainrepo"
HOME_DIR="$TMP/home"
cs_capo_fixture_repo "$MAIN"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/host" "$HOME_DIR/projects"
cs_capo_fixture_project "$TMP" "$HOME_DIR" alpha
printf -- '- alpha [direct-PR] - test project (added 2026-01-01)\n' > "$HOME_DIR/config/projects.md"
printf 'be nice\n' > "$HOME_DIR/config/boss-shared.md"
printf 'manual\n' > "$HOME_DIR/config/backlog-backend.conf"

export CS_ROOT_OVERRIDE="$MAIN"
export CS_HOME="$HOME_DIR"
export CS_DATA_OVERRIDE="$HOME_DIR/data"
export CS_STATE_OVERRIDE="$HOME_DIR/state"
export CS_PROJECTS_OVERRIDE="$HOME_DIR/projects"
export CS_CAPOS_ROOT="$TMP/capos"
export CS_CAPO_CHARTER='Own alpha maintenance end to end.'
export CS_CAPO_SCOPE='All alpha project work.'

BIN="$ROOT/bin/cs-home-seed.sh"
REG="$HOME_DIR/host/capos.md"
CAPO="$TMP/capos/alpha-capo"

# 1. happy-path seed
out=$("$BIN" alpha-capo alpha 2>&1) || fail "seed failed: $out"
assert_contains "$out" "home=$CAPO" "seed prints the home path"
[ "$(cat "$CAPO/.cs-capo-home")" = alpha-capo ] || fail "marker must contain the capo id"
git -C "$CAPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "home must be a git worktree"
[ -z "$(git -C "$CAPO" symbolic-ref --quiet --short HEAD || true)" ] || fail "home worktree must be DETACHED"
[ "$(git -C "$CAPO" rev-parse --path-format=absolute --git-common-dir)" = "$(git -C "$MAIN" rev-parse --path-format=absolute --git-common-dir)" ] \
  || fail "home must be a worktree of the fixture consigliere repo"
for d in data state config projects; do
  [ -d "$CAPO/$d" ] || fail "seed must create $d/ in the home"
done
assert_grep 'Own alpha maintenance end to end.' "$CAPO/config/charter.md" "charter copied into the home"
[ "$(git -C "$CAPO/projects/alpha" remote get-url origin)" = "$(git -C "$HOME_DIR/projects/alpha" remote get-url origin)" ] \
  || fail "seeded project clone must share the main clone's origin"
assert_grep '- alpha [direct-PR]' "$CAPO/config/projects.md" "home project registry carries the main registry line"
line=$(grep '^- alpha-capo ' "$REG") || fail "registry entry missing"
case "$line" in
  "- alpha-capo - Own alpha maintenance end to end. (home: $CAPO; scope: All alpha project work.; projects: alpha; added "*")") : ;;
  *) fail "registry line format drifted: $line" ;;
esac
assert_grep 'DO NOT EDIT' "$CAPO/config/boss-shared.md" "inherited boss-shared carries the do-not-edit header"
assert_grep 'be nice' "$CAPO/config/boss-shared.md" "inherited boss-shared carries the main content"
[ ! -w "$CAPO/config/boss-shared.md" ] || fail "inherited boss-shared must be read-only"
[ "$(cat "$CAPO/config/backlog-backend.conf")" = manual ] || fail "backlog-backend must be copied at seed time"
pass "happy-path seed provisions a marked detached-worktree home"

# 2. re-seed same id converges to one registry line
out=$("$BIN" alpha-capo alpha 2>&1) || fail "re-seed failed: $out"
[ "$(grep -c '^- alpha-capo ' "$REG")" = 1 ] || fail "re-seed must keep exactly one registry line"
pass "re-seed of the same id is idempotent (registry round-trip)"

# 3. validate: healthy passes, duplicate id refused
"$BIN" validate || fail "validate must pass on a healthy registry"
cp "$REG" "$TMP/reg-good"
printf -- '- alpha-capo - dup (home: %s; scope: dup; projects: ; added 2026-01-01)\n' "$TMP/elsewhere" >> "$REG"
out=$("$BIN" validate 2>&1) && fail "duplicate id must fail validate"
assert_contains "$out" "duplicate capo id" "validate names the duplicate id"
cp "$TMP/reg-good" "$REG"
pass "registry validate refuses duplicate ids"

# 3a. an EOF-TRUNCATED registry (last line with no trailing newline) must still
#     bind. A `while read` without the `|| [ -n "$line" ]` guard drops that last
#     line, and with it the only record of a live home - so a second capo could
#     be seeded onto an already-registered home, and an id could be rebound to a
#     different home, with nothing refusing either.
printf -- '- other-capo - Other domain. (home: %s; scope: Other work.; projects: ; added 2026-01-01)' \
  "$TMP/capos/dup-capo" > "$REG"
out=$("$BIN" dup-capo alpha 2>&1) && fail "a home already registered to another capo must refuse"
assert_contains "$out" "is already registered to other-capo" \
  "the duplicate-home refusal must come from the home-assignment check"
assert_absent "$TMP/capos/dup-capo" "the duplicate-home refusal must create no home"

printf -- '- alpha-capo - Alpha domain. (home: %s; scope: Alpha work.; projects: ; added 2026-01-01)' \
  "$TMP/elsewhere" > "$REG"
out=$("$BIN" alpha-capo alpha 2>&1) && fail "rebinding a registered id to a new home must refuse"
assert_contains "$out" "capo id alpha-capo is already registered to home" \
  "the id-rebind refusal must name the existing home"
cp "$TMP/reg-good" "$REG"
pass "an EOF-truncated registry still refuses a duplicate home and an id rebind"

# 3b. a row that does not parse is refused, not skipped. A skipped row is a
#     binding the duplicate and overlap checks never see.
cp "$TMP/reg-good" "$TMP/reg-restore"
printf -- '- wrecked - a row with no structured suffix\n' >> "$REG"
out=$("$BIN" validate 2>&1) && fail "a malformed registry row must fail validate"
assert_contains "$out" "malformed capo registry entry" "validate names the malformed row"
cp "$TMP/reg-restore" "$REG"
pass "registry validate refuses a malformed row instead of skipping it"

# 4. transactional rollback on a forced mid-seed failure (second project's
#    origin dangles, so its clone fails AFTER the home worktree and the first
#    project clone were created)
git init -q "$TMP/src-beta"
printf 'beta\n' > "$TMP/src-beta/README.md"
git -C "$TMP/src-beta" add -A
git -C "$TMP/src-beta" -c user.name=t -c user.email=t@e.invalid commit -qm initial
mkdir -p "$HOME_DIR/projects/beta"
git init -q "$HOME_DIR/projects/beta"
printf 'beta\n' > "$HOME_DIR/projects/beta/README.md"
git -C "$HOME_DIR/projects/beta" add -A
git -C "$HOME_DIR/projects/beta" -c user.name=t -c user.email=t@e.invalid commit -qm initial
git -C "$HOME_DIR/projects/beta" remote add origin "$TMP/nonexistent-remote.git"
printf -- '- beta [direct-PR] - test (added 2026-01-01)\n' >> "$HOME_DIR/config/projects.md"
cp "$REG" "$TMP/reg-before-rollback"
out=$(CS_CAPO_CHARTER='Beta domain.' CS_CAPO_SCOPE='Beta work.' "$BIN" beta-capo alpha beta 2>&1) \
  && fail "seed with a failing clone must fail"
assert_absent "$TMP/capos/beta-capo" "rollback must remove the created home worktree"
cmp -s "$REG" "$TMP/reg-before-rollback" || fail "rollback must restore the registry byte-identically"
assert_absent "$HOME_DIR/data/beta-capo/brief.md" "rollback must remove the generated charter brief"
git -C "$MAIN" worktree list | grep -F "beta-capo" && fail "rollback must prune the worktree registration"
pass "transactional seed rolls back home, clones, brief, and registry on failure"

# 5. missing charter refuses before any mutation
out=$(env -u CS_CAPO_CHARTER -u CS_CAPO_SCOPE "$BIN" gamma-capo alpha 2>&1) && fail "seed without a charter must fail"
assert_contains "$out" "no filled capo charter brief" "missing-charter refusal names the fix"
assert_absent "$TMP/capos/gamma-capo" "missing-charter refusal must create no home"
pass "missing charter refuses loudly with nothing created"

# 6. --no-projects is mutually exclusive with a project list
out=$("$BIN" delta-capo alpha --no-projects 2>&1) && fail "--no-projects with a project list must fail"
assert_contains "$out" "cannot be combined" "mutual-exclusion error is explicit"
pass "--no-projects and a project list are mutually exclusive"

# 7. sweep: FF-only detached-HEAD advance to the main default-branch tip
echo v2 >> "$MAIN/AGENTS.md"
git -C "$MAIN" commit -qam v2
out=$("$BIN" --sweep 2>&1) || fail "sweep failed: $out"
assert_contains "$out" "CAPO_SYNC: capo alpha-capo: updated" "sweep reports the fast-forward"
[ "$(git -C "$CAPO" rev-parse HEAD)" = "$(git -C "$MAIN" rev-parse main)" ] \
  || fail "sweep must advance the home to the main default-branch tip"
[ -z "$(git -C "$CAPO" symbolic-ref --quiet --short HEAD || true)" ] || fail "home must stay detached after sweep"
out=$("$BIN" --sweep 2>&1) || fail "second sweep failed: $out"
[ -z "$out" ] || fail "an already-current sweep must be silent, got: $out"
pass "sweep fast-forwards a registered capo home (silent when current)"

# 8. sweep skips a dirty home and leaves its work untouched
echo local-edit >> "$CAPO/AGENTS.md"
echo v3 >> "$MAIN/AGENTS.md"
git -C "$MAIN" commit -qam v3
out=$("$BIN" --sweep 2>&1) || fail "dirty sweep failed: $out"
assert_contains "$out" "CAPO_SYNC: capo alpha-capo: skipped: dirty working tree" "dirty home is reported skipped"
grep -q local-edit "$CAPO/AGENTS.md" || fail "dirty work must survive the sweep"
[ "$(git -C "$CAPO" rev-parse HEAD)" != "$(git -C "$MAIN" rev-parse main)" ] \
  || fail "a dirty home must not be advanced"
git -C "$CAPO" checkout -q -- AGENTS.md
pass "sweep never disturbs a dirty capo home"

# 9. liveness sweep: respawn only on a confident dead reading
FAKEBIN=$(cs_fakebin "$TMP")
cs_capo_fake_herdr "$FAKEBIN"
cat > "$FAKEBIN/cs-spawn-fake.sh" <<SH
#!/usr/bin/env bash
printf 'spawn %s\n' "\$*" >> "$TMP/spawn.log"
printf 'workspace=w1\npane=w1:p1\nworktree=%s\nproject=%s\nkind=capo\nmode=capo\nyolo=off\nhome=%s\n' "\$2" "\$2" "\$2" > "$HOME_DIR/state/\$1.meta"
echo "spawned \$1"
SH
chmod +x "$FAKEBIN/cs-spawn-fake.sh"
export PATH="$FAKEBIN:$PATH"
export CS_HOME_SEED_SPAWN_BIN="$FAKEBIN/cs-spawn-fake.sh"
: > "$TMP/spawn.log"
cs_write_meta "$HOME_DIR/state/alpha-capo.meta" \
  "workspace=w9" "pane=w9:p9" "kind=capo" "mode=capo" "home=$CAPO"

# 9a. pane holds no agent -> confident dead -> respawn, meta rewritten
out=$(env FAKE_PANE_EXISTS=1 FAKE_AGENT= "$BIN" --sweep 2>&1) || fail "dead-agent sweep failed: $out"
assert_grep 'spawn alpha-capo' "$TMP/spawn.log" "dead capo must be respawned"
assert_contains "$(cat "$TMP/spawn.log")" "--capo" "respawn must use the --capo path"
[ "$(grep '^pane=' "$HOME_DIR/state/alpha-capo.meta")" = "pane=w1:p1" ] || fail "respawn must republish meta"
assert_not_contains "$out" "CAPO_LIVENESS" "a successful guarantee is silent"
pass "liveness sweep respawns a confidently dead capo"

# 9b. live agent -> no respawn
: > "$TMP/spawn.log"
out=$(env FAKE_PANE_EXISTS=1 FAKE_AGENT=codex "$BIN" --sweep 2>&1) || fail "alive sweep failed: $out"
[ ! -s "$TMP/spawn.log" ] || fail "an alive capo must never be respawned"
pass "liveness sweep leaves a live capo alone"

# 9c. inconclusive probe -> skipped, never acted on
: > "$TMP/spawn.log"
out=$(env FAKE_PANE_EXISTS=1 FAKE_AGENT_GET_FAIL=1 "$BIN" --sweep 2>&1) || fail "inconclusive sweep failed: $out"
assert_contains "$out" "CAPO_LIVENESS: capo alpha-capo: skipped: liveness probe inconclusive" \
  "inconclusive probe is reported skipped"
[ ! -s "$TMP/spawn.log" ] || fail "an inconclusive probe must never trigger a respawn"
pass "liveness sweep never acts on an inconclusive reading"

# 9d. failed respawn restores the recorded meta and reports the failure
: > "$TMP/spawn.log"
cat > "$FAKEBIN/cs-spawn-fake.sh" <<'SH'
#!/usr/bin/env bash
echo "error: no herdr" >&2
exit 1
SH
chmod +x "$FAKEBIN/cs-spawn-fake.sh"
out=$(env FAKE_PANE_EXISTS=0 FAKE_AGENT= "$BIN" --sweep 2>&1) || fail "failed-respawn sweep errored: $out"
assert_contains "$out" "CAPO_LIVENESS: capo alpha-capo: respawn failed" "failed respawn is reported"
assert_present "$HOME_DIR/state/alpha-capo.meta" "failed respawn must restore the meta record"
pass "liveness sweep preserves the meta record when respawn fails"

# 9e. a registered capo with no live record at all is the ordinary
# seeded-but-not-yet-launched state: it stays silent and is never respawned.
: > "$TMP/spawn.log"
mv "$HOME_DIR/state/alpha-capo.meta" "$TMP/alpha-capo.meta.away"
out=$(env FAKE_PANE_EXISTS=1 FAKE_AGENT=codex "$BIN" --sweep 2>&1) || fail "unrecorded sweep failed: $out"
[ -z "$out" ] || fail "a seeded-but-unlaunched capo must not produce a liveness line, got: $out"
[ ! -s "$TMP/spawn.log" ] || fail "a capo with no local record must never be blind-respawned"
mv "$TMP/alpha-capo.meta.away" "$HOME_DIR/state/alpha-capo.meta"
pass "sweep stays silent for a registered capo that has no live record yet"

# 9f. a live record with no recorded endpoint is reported, not skipped silently
: > "$TMP/spawn.log"
grep -v '^pane=' "$HOME_DIR/state/alpha-capo.meta" > "$TMP/alpha-nopane.meta"
cp "$HOME_DIR/state/alpha-capo.meta" "$TMP/alpha-capo.meta.orig"
cp "$TMP/alpha-nopane.meta" "$HOME_DIR/state/alpha-capo.meta"
out=$(env FAKE_PANE_EXISTS=1 FAKE_AGENT=codex "$BIN" --sweep 2>&1) || fail "no-endpoint sweep failed: $out"
assert_contains "$out" "CAPO_LIVENESS: capo alpha-capo: skipped: local record has no endpoint" \
  "a record with no endpoint is reported"
[ ! -s "$TMP/spawn.log" ] || fail "a record with no endpoint must never trigger a respawn"
cp "$TMP/alpha-capo.meta.orig" "$HOME_DIR/state/alpha-capo.meta"
pass "sweep reports a live record that has no endpoint"

# 10. sweep retrofits an ABSENT host/activation.conf and never overwrites a
#     present one. A home seeded before per-home activation existed has no
#     file, resolves to afk-only, and can never start its own turn.
rm -f "$CAPO/host/activation.conf"
out=$(env FAKE_PANE_EXISTS=1 FAKE_AGENT=codex "$BIN" --sweep 2>&1) || fail "retrofit sweep failed: $out"
assert_contains "$out" "CAPO_SYNC: capo alpha-capo: activation set to always (was unset)" \
  "an absent activation is reported when filled"
[ "$(cat "$CAPO/host/activation.conf")" = always ] || fail "sweep must retrofit activation to always"
out=$(env FAKE_PANE_EXISTS=1 FAKE_AGENT=codex "$BIN" --sweep 2>&1) || fail "idempotent sweep failed: $out"
[ -z "$out" ] || fail "a converged sweep must be silent, got: $out"
pass "sweep retrofits an absent host/activation.conf (idempotently)"

# 10a. a deliberate value survives: the retrofit fills absence only
printf 'off\n' > "$CAPO/host/activation.conf"
out=$(env FAKE_PANE_EXISTS=1 FAKE_AGENT=codex "$BIN" --sweep 2>&1) || fail "deliberate-value sweep failed: $out"
[ "$(cat "$CAPO/host/activation.conf")" = off ] || fail "sweep must never overwrite a deliberate activation choice"
[ -z "$out" ] || fail "leaving a present value alone must be silent, got: $out"
printf 'always\n' > "$CAPO/host/activation.conf"
pass "sweep never overwrites a present host/activation.conf"

rm -f "$CAPO/host/activation.conf" "$TMP/external-activation"
ln -s "$TMP/external-activation" "$CAPO/host/activation.conf"
out=$(env FAKE_PANE_EXISTS=1 FAKE_AGENT=codex "$BIN" --sweep 2>&1) || fail "dangling-symlink sweep failed: $out"
[ -L "$CAPO/host/activation.conf" ] || fail "sweep must preserve a dangling activation symlink"
assert_absent "$TMP/external-activation" "sweep must not create a dangling activation symlink target"
[ -z "$out" ] || fail "leaving a dangling activation symlink alone must be silent, got: $out"
rm "$CAPO/host/activation.conf"
printf 'always\n' > "$CAPO/host/activation.conf"
pass "sweep preserves a dangling host/activation.conf symlink"

mv "$CAPO/host" "$TMP/capo-host"
mkdir "$TMP/external-host"
ln -s "$TMP/external-host" "$CAPO/host"
out=$(env FAKE_PANE_EXISTS=1 FAKE_AGENT=codex "$BIN" --sweep 2>&1) || fail "host-symlink sweep failed: $out"
[ -L "$CAPO/host" ] || fail "sweep must preserve a symlinked host directory"
assert_absent "$TMP/external-host/activation.conf" "sweep must not create activation through a symlinked host directory"
assert_contains "$out" "CAPO_SYNC: capo alpha-capo: skipped: unsafe host/ for activation" \
  "a symlinked host directory must be reported as unsafe"
rm "$CAPO/host"
mv "$TMP/capo-host" "$CAPO/host"
pass "sweep rejects a symlinked host directory"

pass "cs-home-seed provisioning, rollback, and sweep behavior"
