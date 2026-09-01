---
name: capo-provisioning
description: >-
  Agent-only reference for persistent capo setup and retirement.
  Use when creating, seeding, validating, launching, recovering, handing backlog to, pushing inherited local material into, or retiring a capo home, or when editing host/capos.md.
  Covers detached-worktree homes, transactional seeding, inherited-domain record intake, project clone restrictions, inherited local-material push, idle charter, handoff helper, and teardown safety.
user-invocable: false
---

# capo-provisioning

Use this reference before creating, seeding, validating, launching, handing backlog to, recovering, pushing inherited local material into, or retiring a persistent capo, and before editing `host/capos.md`.

Keep the always-inline routing rules in `AGENTS.md` authoritative: route by natural-language `scope:`, local-only projects stay with the main consigliere, and capos are idle by default.

## Routing table

`host/capos.md` has one parser-compatible line per persistent capo:

```markdown
- <id> - <one-sentence charter summary> (home: <absolute-home-path>; scope: <natural-language responsibility>; projects: <project-a>, <project-b>; added <date>)
```

`bin/cs-home-seed.sh` writes that line and `bin/cs-capo-registry-lib.sh` is the single owner of reading it back, in every consumer; a row it cannot parse is refused or surfaced with a reason, never silently skipped.
Each registry entry stays concise and single-line: the summary is one sentence naming the durable charter, `scope:` is the natural-language intake responsibility, `projects:` is the non-exclusive clone list, and any extra prose is limited to genuinely domain-specific hard rules that change routing or safety for that capo.
The `home:` path points to the seeded home containing `config/charter.md`; no extra registry pointer field is needed.
The home-seeded `config/charter.md` is the sole owner of boilerplate idle-by-default behavior, the normal delegation lifecycle, and standard escalation contracts, so point to that charter rather than restating those contracts in the registry entry.
The `scope:` field is used during intake.
The `projects:` field is a non-exclusive clone list, not ownership.

## Home mechanics

A capo home is a PLAIN DETACHED git worktree of this consigliere repo at `${CS_CAPOS_ROOT:-~/.consigliere/capos}/<id>`, marked with a `.cs-capo-home` file containing the capo id.
It is never a herdr-managed worktree and never pooled or leased: a capo home must survive herdr server restarts and empty workspaces, so its lifetime is owned by seed and retirement alone.
The detached HEAD follows the main repo's default-branch tip through the guarded fast-forward sweep, never a branch of its own.
Capos run on the root session's harness (codex or claude) like every other soldier, and that harness selects the model and the reasoning level.

## Charter and seed

Scaffold a capo charter with:

```sh
bin/cs-brief.sh <id> --capo {<project>...|--no-projects}
```

The scaffold writes a charter brief instead of a task brief.
Set `CS_CAPO_CHARTER='<charter>'` to fill the charter text and `CS_CAPO_SCOPE='<scope>'` when the routing scope differs.
If you scaffold without `CS_CAPO_CHARTER`, replace the `{TASK}` placeholder before seeding.
Pass `--no-projects` instead of a project list to scaffold a project-less charter for a domain whose subject is the consigliere repo itself; its home is already a worktree of this repo, and its soldiers take worktrees of the same repo.
`--no-projects` is mutually exclusive with a project list, and omitting both still fails loudly, so an accidental omission is never mistaken for a deliberate project-less seed.
Re-seeding a populated home as project-less is refused non-destructively when the home contains project clones or `config/projects.md` entries.
Retire or clean that home first, and re-scaffold a stale project-bearing charter with `--no-projects` before seeding.
Keep custom charter text focused on the persistent responsibility, available project clones, and genuinely domain-specific hard rules.
The scaffolded charter, later copied to `config/charter.md`, owns the standard lifecycle and escalation wording, including the marked-request return channel and idle-by-default contract; preserve those generated sections unless the domain genuinely needs a hard rule.

Provision the persistent home and registry entry after the charter is filled:

```sh
bin/cs-home-seed.sh <id> {<project>...|--no-projects}
```

It creates the detached worktree home at `${CS_CAPOS_ROOT:-~/.consigliere/capos}/<id>`, writes the `.cs-capo-home` identity marker (which must remain in place for home validation), seeds the private `data/`, `state/`, `config/`, and `projects/` dirs, clones the project list, copies the charter to `config/charter.md`, seeds the inherited local material, and writes the `host/capos.md` entry.
`bin/cs-home-seed.sh` refuses to copy a missing or placeholder charter; a direct seed without a preexisting brief requires `CS_CAPO_CHARTER`.
Run `bin/cs-home-seed.sh validate` when checking registry integrity; it refuses duplicate ids, duplicate homes, and nested or overlapping homes.

Seeding is transactional.
If validation, worktree creation, cloning, no-mistakes initialization, inheritance, or registry update fails, generated briefs, the new home worktree, new project clones, and registry edits are rolled back.

Capo project lists may include `no-mistakes` and `direct-PR` projects only.
`local-only` projects stay with the main consigliere.
For `no-mistakes` projects, seeding initializes only projects newly cloned into a capo home and refuses to mutate a preexisting clone that is not already initialized.

Launch the seeded capo with:

```sh
bin/cs-spawn.sh <id> <home> --capo
```

It validates the `.cs-capo-home` marker, ensures the `capo-<id>` home workspace, and launches the root harness there (via `bin/cs-harness-lib.sh`) with `CS_HOME` pointing at the home.

## Record intake

Seeding carries a charter, inherited configuration, shared boss preferences, project clones, and queued backlog rows into the new home, but none of that tells the capo what its domain has already shipped.
Before the capo takes its first work, classify the domain.

A greenfield domain has no shipped history, no live deployment, and no inherited plans; it needs nothing from this section and intake is done.

An existing or inherited domain has shipped history, so reconcile the inherited record against reality before the capo treats any of it as open work:

- Reconcile every inherited plan, proposal, and queued row against `origin/main` in the relevant project clones and against the live deployment or running system, not against the plan's own prose.
- Carry over only genuinely open work, and only durable knowledge that is still live.
- Never carry a plan row for work that has already shipped; a live backlog retains only the configured recent Done entries, so an inherited queue structurally over-represents plans and under-represents deliveries, and shipped work looks open unless it is checked against the code and the deployment.
- Record what could not be reconciled - a plan whose shipped state is genuinely undeterminable - as an explicit open question in the capo home rather than silently dropping it or silently importing it as open work.

The result is the capo's starting picture of its domain: what is live, what is genuinely open, and what remains unknown.

## Sync and inherited local material

This section is the single owner of the capo sync and inherited-local-material propagation contract; `AGENTS.md` points here.
The locked session-start bootstrap runs `bin/cs-home-seed.sh --sweep`, which fast-forwards every registered capo home to the main repo's current default-branch tip.
That is a purely local detached-HEAD advance, FF-only, never a fetch, force, merge, or stash; dirty or diverged homes are skipped with a `CAPO_SYNC:` line and their work left untouched.
The fast-forward never touches the gitignored operational dirs, so a capo's backlog, projects, and in-flight work are never disturbed.
The sweep also converges capo activation according to the contract owned by `bin/cs-home-seed.sh --help`.

Inheritance is deliberately tiny and one-way (`bin/cs-inherit-lib.sh` owns the allowlist):

- `config/boss-shared.md` is main-authoritative and propagated into each capo home's `config/` as a read-only (mode 444) copy with a generated do-not-edit header, converged at seed time and on every sweep.
- `config/backlog-backend.conf` is copied once at seed time only.

Every convergence rewrites the capo copy only when it no longer matches what the main copy renders to; a divergent capo-local edit is quarantined to a dated private sibling and reported as a `CAPO_SYNC:` line, and a main-copy absence converges by quarantining the capo copy too.
Never copy any capo `config/boss-shared.md` back into the primary.
Keep each home's `config/boss.md` domain-local, and keep every `config/learnings.md` fully local; route fleet-general facts into tracked documentation instead of inventing shared learnings propagation.

The same `--sweep` also guarantees liveness: for every live capo meta (`state/<id>.meta` with `kind=capo` and a recorded pane), it probes the pane for a real agent through `bin/cs-herdr-lib.sh` and respawns via `bin/cs-spawn.sh <id> <home> --capo` only on a confident dead reading.
An inconclusive probe is reported as a `CAPO_LIVENESS:` skip and never acted on, because a false-dead reading would spawn a duplicate supervisor into the same home.
A `kind=capo` meta with no recorded endpoint is reported as a `CAPO_LIVENESS:` recovery condition and is never respawned by the sweep.
A registered capo with no meta is the ordinary seeded-but-not-yet-launched state, so the sweep stays silent and does not blind-respawn it from the registry.

## Marked requests and pending replies

Route work to a capo through fail-closed `bin/cs-send.sh`; a resolved `kind=capo` target automatically gets the from-consigliere marker (`bin/cs-marker-lib.sh`) plus a privacy-safe `corr=<id>` token, and a durable parent-owned pending-reply record is created under `state/pending-replies/` before delivery.
`bin/cs-pending-reply-lib.sh` owns that contract: delivery success is never reply success, the watcher resolves a record only from a correlated parent status line or status-pointed document, sends exactly one recovery repost when a completed turn produced no correlated report, and escalates once - durably, never expiring an unresolved record - if the recovery turn is also missed.
Do not read a capo's chat to check on a request; the correlated status channel is the only return path.

## Backlog handoff

Apply `AGENTS.md` section 10's work-items-only backlog contract before creation or handoff.
When a capo is created for a domain, existing main-backlog items that fall under its scope should become its work instead of staying stranded in the main backlog.
Scope-matching is consigliere's judgment against the capo's natural-language scope, not a keyword rule.
For an existing or inherited domain, reconcile each selected item against shipped reality per the record-intake step above before moving it; a row for already-shipped work must not be handed off.
Read `config/backlog.md`, pick queued items that fit the new scope, and move them with:

```sh
bin/cs-backlog-handoff.sh <capo-id> <item-key>...
```

The helper resolves and validates the capo home from `host/capos.md`, then delegates the item move to `tasks-axi mv` (the single owner of the backlog format), which moves each named item - and a whole connected set, blocker plus dependents, atomically - from the main `config/backlog.md` into the capo home's `config/backlog.md`.
This delegated route remains required when `config/backlog-backend.conf=manual`, which controls only routine consigliere backlog edits.
It accepts in-scope `## Queued` entries only and refuses `## In flight` and historical `## Done` entries; Done records stay with their home for pruning or archiving.
It refuses a selected item with a single-space or tab-indented continuation rather than risk leaving content orphaned.
It is idempotent; an item already in the capo backlog is skipped.
It refuses any destination that is not a genuine seeded consigliere home with safe operational directories and a matching `.cs-capo-home` marker, so a move can never land in a project.
After a successful move it durably wakes the capo's recorded receiver when one exists; if the wake fails, rerun the same handoff or `bin/cs-backlog-handoff.sh --resume-pending` to retry delivery while the moved backlog stays durable.
Do not hand off `local-only` items.

## Recovery

For `kind=capo` meta with a dead endpoint or no recorded workspace, treat the capo as a dead persistent direct report and respawn it with:

```sh
bin/cs-spawn.sh <id> <home> --capo
```

Use the recorded `home=` in meta.
A meta with no recorded endpoint is a reported recovery condition, not permission to search herdr by name or respawn blindly.
If meta is missing but `host/capos.md` still registers the capo, leave it idle as a seeded-but-not-yet-launched home rather than respawning from the registry entry.
A restart never re-seeds: the home, charter, and registry entry are durable, and the bootstrap sweep re-converges the home as described above on the next session start.

Do not reconstruct a capo's whole tree from the main home.
The main consigliere reconciles only direct reports.
Each capo is a consigliere in its own home, so it runs recovery on startup and reconciles its own soldiers.
A capo's recovery reconciles only work that is already its own and then idles.
It never initiates a survey or audit during recovery.

## Retirement and teardown

A capo is persistent by default.
An empty queue is healthy and does not trigger teardown.
Run `bin/cs-teardown.sh <id>` for `kind=capo` only when the boss or main consigliere explicitly decides to retire that persistent capo.

The safety check is the capo's own home.
Teardown refuses while its `state/*.meta` contains in-flight work, and refuses to remove a directory that is not marked by `.cs-capo-home`.
When safe, teardown closes the capo pane and workspace, removes the home through `git worktree remove` plus prune (so the repo's worktree registry stays consistent), removes the `host/capos.md` route, and clears the main home metadata.
Removing the home never touches anything under `projects/` clones.

With `--force`, teardown is the explicit discard path.
It discards child work and state inside the capo home, removes the route, and removes the retired capo home.
Never use `--force` unless the boss explicitly said to discard the work.
