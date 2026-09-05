#!/usr/bin/env bash
# Behavior (portable): respawning an existing capo (dead-capo recovery, or any
# other re-provisioning of the same capo id) must preserve endpoint-generation
# lineage, so a message already queued against the pre-respawn generation
# still validates through cs_meta_endpoint_generation_known afterward.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$ROOT/bin/cs-meta-lib.sh"
# shellcheck source=bin/cs-message-lib.sh
. "$ROOT/bin/cs-message-lib.sh"

SPAWN="$ROOT/bin/cs-spawn.sh"
TMP=$(cs_test_tmproot cs-spawn-capo-endpoint-generation)
FAKEBIN=$(cs_fakebin "$TMP")
cs_git_identity

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "status --json") printf '%s\n' '{"server":{"protocol":16}}' ;;
  "pane report-metadata") : ;;
  "pane run") : ;;
  "agent start")
    shift 2
    kind= pane= name=$1; shift
    in_argv=0
    while [ "$#" -gt 0 ]; do
      if [ "$in_argv" -eq 1 ]; then
        :
      else
        case "$1" in
          --kind) kind=$2; shift ;;
          --pane) pane=$2; shift ;;
          --) in_argv=1 ;;
        esac
      fi
      shift
    done
    printf '{"result":{"agent":{"agent":"%s","agent_status":"idle","interactive_ready":true}}}\n' "$kind"
    ;;
  "pane wait-output") printf '{"result":{"matched":true}}\n' ;;
  "workspace list") printf '{"result":{"workspaces":[]}}\n' ;;
  "workspace create") printf '{"result":{"workspace":{"workspace_id":"wcapo"}}}\n' ;;
  "pane list") printf '{"result":{"panes":[{"pane_id":"wcapo:p1","workspace_id":"wcapo"}]}}\n' ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"wcapo:p1","cwd":"%s"}}}\n' "${CS_FAKE_SPAWN_WORKTREE:-}" ;;
  "pane read") printf '%s\n' $'\342\200\272 ' ;;
  "agent get") printf '{"result":{"agent":{"agent":"codex","agent_status":"idle"}}}\n' ;;
  "pane process-info")
    printf '{"result":{"process_info":{"shell_pid":10,"foreground_processes":[{"pid":20,"argv0":"codex"}]}}}\n' ;;
  "agent prompt") printf '{"result":{"type":"agent_prompted"}}\n' ;;
  *) printf '{}\n' ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/data/foo" "$HOME_DIR/state/inbox" "$HOME_DIR/config"
printf 'charter\n' > "$HOME_DIR/data/foo/brief.md"
CAPO_HOME="$TMP/capo-home"
mkdir -p "$CAPO_HOME"
: > "$CAPO_HOME/.cs-capo-home"
CAPO_ABS=$(cd "$CAPO_HOME" && pwd -P)

spawn_capo() { # <endpoint-generation>
  env PATH="$FAKEBIN:$PATH" CS_HARNESS_OVERRIDE=codex \
    CS_HOME="$HOME_DIR" CS_DATA_OVERRIDE="$HOME_DIR/data" CS_STATE_OVERRIDE="$HOME_DIR/state" \
    CS_CLAUDE_JSON="$TMP/claude.json" CS_CODEX_TOML="$TMP/codex.toml" \
    CS_ENDPOINT_GENERATION="$1" CS_FAKE_SPAWN_WORKTREE="$CAPO_ABS" \
    "$SPAWN" foo "$CAPO_HOME" --capo >/dev/null
}

spawn_capo gen-1 || fail "initial capo spawn failed"
[ "$(cs_meta_get "$CAPO_ABS/state/foo.meta" endpoint_generation)" = gen-1 ] \
  || fail "initial spawn did not record gen-1"

# The message that will be orphaned by a naive respawn: sent while the capo
# was still at gen-1, queued in root's inbox.
created_at=1700000000
message_id='message-capo-respawn-0000000000001'
cs_message_publish "$HOME_DIR/state/inbox" \
  "schema=cs-message.v1" "message_id=$message_id" "correlation_id=$message_id" \
  "sequence=1" "kind=result" "from_task_id=foo" "to_task_id=root" \
  "from_home=$CAPO_ABS" "from_endpoint_generation=gen-1" \
  "to_endpoint_generation=root-generation" "summary=work done at gen-1" "artifact=" \
  "commit_sha=" "pull_request=" "created_at=$created_at" || fail "message setup"

# Dead-capo recovery respawns through the identical --capo invocation
# (cs-spawn.sh refuses to relaunch a capo any other way). cs-spawn.sh also
# refuses outright if root's OWN tracking meta still exists ("already has
# metadata"), so the real sweep (bin/cs-home-seed.sh's sweep_liveness_meta)
# moves ONLY that copy aside first, restoring it on failure - it never
# touches the capo's OWN copy under its home, which is what this fix must
# correctly carry forward. Replicate that exact real-world precondition.
mv "$HOME_DIR/state/foo.meta" "$HOME_DIR/state/foo.meta.pre-respawn"
spawn_capo gen-2 || fail "capo respawn failed"
rm -f "$HOME_DIR/state/foo.meta.pre-respawn"
[ "$(cs_meta_get "$CAPO_ABS/state/foo.meta" endpoint_generation)" = gen-2 ] \
  || fail "respawn did not record gen-2"

cs_meta_endpoint_generation_known "$CAPO_ABS/state/foo.meta" gen-1 "$created_at" \
  || fail "a message queued against the pre-respawn generation must still validate (this is the exact check bin/cs-recover.sh:284-291 runs)"
pass "a message queued against a capo's pre-respawn generation still validates after cs-spawn.sh --capo respawns it"

pass "capo-respawn endpoint-generation lineage"
