# Grok Bot pack

This file is the installer and upgrader for consigliere's Grok Bot pack.
If you are a Grok Bot session told to follow this file, execute the numbered instructions in order instead of summarizing them.

## What this is

The source pack in [`grokbot/`](../grokbot/) is a pinned port of [grok-ship](https://github.com/kunchenguid/grok-ship/) at commit `ae1f5a787e544dcec69b819370615b2fcbef0eab`.
It targets xAI's cloud and web Grok Bot platform.
It does not target consigliere's terminal harnesses or the Grok CLI coding agent.
This is a one-time editorial fork that evolves independently after the port.
There is no ongoing synchronization or shared-schema coupling with consigliere core.

## Quick start

Tell any Grok Bot: `follow https://github.com/douglasjarquin/consigliere/blob/main/docs/grokbot.md`

That single instruction installs the pack on a new deployment.
Following the same URL again refreshes an existing deployment and is the upgrade path.
The refresh is idempotent because it replaces only the pack subtree, reapplies a non-destructive schema, and preserves the deployment's durable siblings.

## Deployment layout

Ask the human for the existing Grok Casino root when it is not already known.
The usual root is `/home/box/agent-data/grok-ship`, but use it only when it is the confirmed deployment path.

| Path | Ownership |
| --- | --- |
| `$ROOT/pack/` | Replaceable charter, skill, schema, and license content from this repository's `grokbot/` tree. |
| `$ROOT/factory.db` | Durable SQLite backlog that remains outside the replaceable pack. |
| `$ROOT/reports/` | Durable task reports that remain outside the replaceable pack. |

Never replace, delete, or move `$ROOT/factory.db` or `$ROOT/reports/`.
The canonical schema source in this repository is `grokbot/skills/project-management/schema.sql`.

## Install or refresh

1. Resolve the deployment root and back up an existing database.

   Ask the human for the existing Grok Casino deployment path if it is unknown.
   Set `ROOT` to that confirmed absolute path before continuing.
   If the database already exists, create a timestamped sibling backup before any schema operation.

   ```sh
   set -eu
   ROOT='<confirmed Grok Casino root>'
   export ROOT
   case "$ROOT" in
     /*) ;;
     *) printf 'ROOT must be an absolute path\n' >&2; exit 1 ;;
   esac
   [ -d "$ROOT" ] || { printf 'ROOT must already be an existing directory\n' >&2; exit 1; }
   [ ! -L "$ROOT" ] || { printf 'ROOT must not be a symlink\n' >&2; exit 1; }
   ROOT_REAL=$(cd "$ROOT" && pwd -P)
   [ "$ROOT_REAL" = "$ROOT" ] || { printf 'Use the canonical deployment path for ROOT\n' >&2; exit 1; }
   for target in "$ROOT/factory.db" "$ROOT/pack" "$ROOT/reports"; do
     [ ! -L "$target" ] || { printf 'Deployment paths must not be symlinks: %s\n' "$target" >&2; exit 1; }
   done
   if [ -f "$ROOT_REAL/factory.db" ]; then
     BACKUP="$ROOT_REAL/factory.db.bak-$(date +%Y%m%dT%H%M%S)"
     [ ! -e "$BACKUP" ] || { printf 'Refusing to overwrite existing backup: %s\n' "$BACKUP" >&2; exit 1; }
     cp "$ROOT_REAL/factory.db" "$BACKUP"
   fi
   ```

   Run the shell snippets in this document in one shell session so the fail-closed settings and resolved paths remain active.

2. Create the replaceable pack directory and durable reports directory.

   ```sh
   mkdir -p "$ROOT_REAL/pack" "$ROOT_REAL/reports"
   [ ! -L "$ROOT_REAL/pack" ] || { printf 'Pack destination must not be a symlink\n' >&2; exit 1; }
   [ ! -L "$ROOT_REAL/reports" ] || { printf 'Reports directory must not be a symlink\n' >&2; exit 1; }
   PACK_REAL=$(cd "$ROOT_REAL/pack" && pwd -P)
   REPORTS_REAL=$(cd "$ROOT_REAL/reports" && pwd -P)
   [ "$PACK_REAL" = "$ROOT_REAL/pack" ] || { printf 'Pack destination escaped ROOT\n' >&2; exit 1; }
   [ "$REPORTS_REAL" = "$ROOT_REAL/reports" ] || { printf 'Reports directory escaped ROOT\n' >&2; exit 1; }
   ```

3. Fetch the current consigliere `grokbot/` subtree and replace only `$ROOT/pack/`.

   Use a temporary sparse checkout so the fetched consigliere commit can be recorded exactly.
   The `rsync --delete` destination is deliberately scoped to `$ROOT/pack/`.
   It must never target `$ROOT`, `$ROOT/factory.db`, or `$ROOT/reports/`.

   ```sh
   CHECKOUT=$(mktemp -d)
   git clone --depth 1 --filter=blob:none --sparse --branch main --single-branch https://github.com/douglasjarquin/consigliere.git "$CHECKOUT"
   git -C "$CHECKOUT" sparse-checkout set grokbot
   CONSIGLIERE_SHA=$(git -C "$CHECKOUT" rev-parse HEAD)
   [ "$PACK_REAL" = "$ROOT_REAL/pack" ] || { printf 'Pack destination changed unexpectedly\n' >&2; exit 1; }
   rsync -a --delete "$CHECKOUT/grokbot/" "$PACK_REAL/"
   ```

   Let the shared computer's normal temporary-file lifecycle reclaim `$CHECKOUT` after the installation has been verified.
   The full-tree copy carries `LICENSE` into the deployed pack.

4. Apply the canonical schema to the durable database.

   The schema contains only `CREATE TABLE IF NOT EXISTS` statements.
   It never drops a table or replaces existing rows.

   ```sh
   [ ! -L "$ROOT_REAL/factory.db" ] || { printf 'Database path must not be a symlink\n' >&2; exit 1; }
   sqlite3 "$ROOT_REAL/factory.db" < "$PACK_REAL/skills/project-management/schema.sql"
   ```

5. Verify that `lavish-axi` version 0.1.53 or newer is available on the shared computer.

   ```sh
   lavish-axi --version
   ```

   If it is missing or older, run the upstream installation channel and then verify the version again.

   ```sh
   npx -y lavish-axi@latest
   lavish-axi --version
   ```

   Confirm with the human that URLs served from the shared computer are reachable from their own computer.
   Do not claim the live review loop works until that reachability is confirmed.

6. Detect and authenticate the forge CLI used by the human's repositories.

   Check for GitHub `gh`, GitLab `glab`, Bitbucket tooling, or Cursor Origin rather than assuming GitHub.
   Use the selected forge's own status command, such as `gh auth status` or `glab auth status`.
   Ask the human to complete missing account connections without asking them to paste a token into chat.
   Cursor cloud agents separately need the human's Cursor account connected to the selected source control.

7. Record the exact source versions in `$ROOT/pack/.grokbot-version`.

   Reuse `CONSIGLIERE_SHA` captured from the sparse checkout in step 3.
   This command writes exactly two lines.

   ```sh
   printf 'upstream %s\nconsigliere %s\n' \
     'ae1f5a787e544dcec69b819370615b2fcbef0eab' \
     "$CONSIGLIERE_SHA" > "$PACK_REAL/.grokbot-version"
   ```

8. Reuse or create the Consigliere Grok Bot agent.

   Inspect the existing Grok Bot roster first.
   If a Consigliere already runs this pack, reuse it and refresh its description from `$ROOT/pack/GROK_BOT_CONSIGLIERE.md`.
   Do not create a second Consigliere.
   If none exists, create an agent named `Consigliere` from `$ROOT/pack/GROK_BOT_CONSIGLIERE.md`.
   If you are already Consigliere, update your own description instead of cloning yourself.

9. Register or refresh the four global workflows.

   Use each skill's description field as the workflow description.
   Register exactly these workflows:

   - Lavish session from `$ROOT/pack/skills/lavish-session/SKILL.md`.
   - Adversarial review from `$ROOT/pack/skills/adversarial-review/SKILL.md`.
   - Project management from `$ROOT/pack/skills/project-management/SKILL.md`.
   - Sitdown from `$ROOT/pack/skills/sitdown/SKILL.md`.

   Do not install extra plugins without the human's approval.

10. Complete the Consigliere handshake and first-install handoff.

    Message Consigliere with a task id such as `CS-READY`.
    Tell Consigliere that the skills are installed, give it the database path, and require a ready or blocked reply against that same task id.
    Ask Consigliere to leave the human a greeting message.
    On a first install only, tell the human that this starter bot is leftover and that they can delete it from the Grok Bot sidebar.
    Do not attempt to delete the starter bot yourself.
    On a refresh, keep the existing Consigliere and skip the starter-bot handoff.

## Verification on the shared computer

Before reporting success, verify all of the following from the live Grok Bot session:

- `$ROOT/pack/LICENSE` exists.
- `$ROOT/pack/GROK_BOT_CONSIGLIERE.md` and all four registered workflow sources exist.
- `sqlite3 "$ROOT/factory.db" ".tables"` lists both `projects` and `tasks`.
- `$ROOT/reports/` still exists.
- `$ROOT/pack/.grokbot-version` contains exactly the pinned upstream line and fetched consigliere line.
- Consigliere replies ready or reports a concrete blocker against the handshake task id.
- The human confirms that the shared computer's Lavish URL is reachable.

## License and provenance

The `grokbot/` subtree is third-party content from grok-ship, copyright Kun Chen 2026, distributed under the MIT license in [`grokbot/LICENSE`](../grokbot/LICENSE).
Consigliere has no repository-wide top-level license.
The pack copy in step 3 carries that upstream license into every deployed refresh.

## CI boundary

Consigliere's CI verifies the vendored files, applies the schema to a scratch SQLite database, and runs the vendored Python test.
It cannot execute the ten install or refresh steps against the human's deployment.
Those steps require a live Grok Bot session with shell access to the actual shared computer, which is a different machine and platform outside this repository's reach.
