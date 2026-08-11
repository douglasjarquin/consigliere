---
name: vault
description: Put the session's durable knowledge in the vault - sweep this conversation for anything worth keeping and file it to disk before a context reset. Use when the boss invokes /vault (e.g. "/vault", "put that in the vault", "vault what you've learned", and the retired "/stow" phrasing), before a session reset or context compaction, or periodically to keep operational memory current.
user-invocable: true
---

# vault

Sweep this session for durable knowledge that only exists in conversation right now, and write it to the disk locations consigliere already prints in the next session-start context digest.
The goal is a session that is safe to reset or destroy because everything durable has already been captured.

This skill is the single owner of the memory-lifecycle contract: what a memory entry is, how long it lives, how it is reinforced, where it goes when it stops being current, and how a sweep reaches the rest of the fleet.

## What it does

1. **Sweep the session for uncaptured durable knowledge.**
   Read back over this conversation and look for:
   - Operational learnings: fleet-local facts and gotchas discovered while operating consigliere (a script's sharp edge, a herdr/codex/claude quirk, a recurring false alarm and its real cause).
   - Boss preferences expressed in passing: a working-style or approval preference the boss stated conversationally rather than through the destination selected by AGENTS.md's knowledge-routing table.
   - Standing decisions: a choice the boss made this session that should govern future work rather than only this task - a delivery posture, a tool or library choice, a policy on how a recurring situation is handled, a thing consigliere is now expected to do or never do.
     A standing decision is durable knowledge in its own right, not a task note: file it where it will be read again, not only where it was made.
   - Project-intrinsic facts discovered: build, test, release, or architecture facts about a project that belong in that project's own `AGENTS.md`.
   - Undone next steps: anything left open that has not yet been filed as backlog work.

2. **Route each finding using AGENTS.md's knowledge-routing table.**
   AGENTS.md (section 6, "Project and knowledge management") is the single source of truth for where each kind of knowledge belongs.
   Read that table and route each finding there instead of re-deriving the mapping here.

3. **Write within consigliere's existing write boundaries.**
   This skill does not grant any new write permission; it only prompts consigliere to use the boundaries that already exist (AGENTS.md section 1):
   - Boss preferences and fleet-local operational facts: hand-write directly to the destination selected by AGENTS.md's knowledge-routing table, using inspect-then-update every time.
     Before writing, inspect the destination, find the existing bullet or section the finding duplicates or supersedes, and rewrite it in place rather than adding a new trailing entry.
     `config/learnings.md` may not exist yet; create it on first local learning, in the same dated, evidence-backed, curated style as `config/boss.md`.
   - Project-intrinsic knowledge: never hand-write a project's `AGENTS.md`.
     Route it through a normal ship task so a soldier records it via `bin/cs-ensure-agents-md.sh` and commits it through that project's delivery pipeline, exactly as section 6 describes.
     If the fleet is live, delegate this to a soldier rather than doing it inline.
   - Knowledge about consigliere itself: this repo's own `AGENTS.md` (or other shared, tracked material), shipped through the normal branch -> no-mistakes -> PR -> boss-merge pipeline for this repo (section 1), never hand-committed straight to `main`.
   - Task-scoped notes: inspect the relevant backlog item with `tasks-axi show <id> --full`, judge whether the new note is new, duplicate, superseding, or obsolete, then write a considered replacement body with `tasks-axi update <id> --body-file <path>`.
     When the replacement intentionally supersedes prior state that should remain recoverable, add `--archive-body` to that update command so the prior body stays recoverable without copying it into the replacement.
     Never append.
     If hand-editing `config/backlog.md` per the active backend, make the same inspect-then-update edit in place.
   - Undone next steps: file each as a queued backlog item (section 10), with `blocked-by` recorded if it genuinely depends on something else.

4. **Curate with inspect-then-update.**
   Every write starts by reading the current destination and deciding how the finding changes what is already there.
   Read the destination's current contents before writing, and classify the finding against them as exactly one of:
   - **new** - nothing on disk asserts this yet, so it becomes a new entry, marked with its tier.
   - **duplicate** - an existing entry already asserts it, so nothing new is written; reinforce that entry instead (see "Reinforcement" below) when this session actually used or re-verified the fact.
   - **superseding** - an existing entry asserts an older version of this fact, so rewrite that entry in place to the current form and reset its clock.
   - **obsolete** - this session proved an existing entry is no longer true, so retire that entry to the archive and write the corrected fact only if the corrected fact is itself worth keeping.

   Use this checklist before writing:
   - Which existing bullet, section, or task body does this supersede?
   - Can this be a one-sentence rewrite instead of a new entry?
   - Should an older bullet or note be retired to the archive because it is now obsolete?
   - Which tier does the resulting entry belong in, and does a perishable entry carry a checkable expiry condition?

   When a finding overlaps or supersedes something already on disk, rewrite or retire the existing entry instead of piling on a new one.
   Graduation moves are limited to exactly three: promote a learning to the shared `AGENTS.md` via PR, fold it into the boss-preference destination selected by AGENTS.md, or retire a stale entry to the archive.
   Do not invent other graduation paths.

5. **Run the decay pass** over this home's curated memory, per "Tiers and decay" below, before judging any budget.

6. **Bring over-budget files back under budget**, per "Over budget" below.

7. **Cascade to the capo homes**, per "Cascade" below, when this sweep is running in the primary home.

8. **Report to the boss.**
   Summarize, in plain outcome language (section 9): what went into the vault and where, what was retired to the archive and why, what was filed to the backlog, what each capo home's sweep did, and whether the session is now safe to reset or destroy - i.e. whether every durable finding from this sweep now lives on disk rather than only in this conversation.
   If something could not be captured yet (for example, project-intrinsic knowledge waiting on a soldier to land it, or a capo home that could not be reached), say so explicitly rather than reporting the session fully safe.

## Tiers and decay

Curated memory has a lifecycle: some of it is a standing preference that is true until the boss changes their mind, and some of it is a fact about a moving system that quietly stops being true.
Without a lifecycle both kinds accumulate forever and a session cannot tell which is which, so every entry carries its tier in a trailing HTML comment marker:

```
- The boss merges every PR himself, even under yolo. <!-- vault: pinned -->
- herdr recycles pane ids across restarts, so a recorded pane is a hint, not an identity. <!-- vault: aging; reinforced 2026-08-11 -->
- gh-axi's PR capacity output is the two-column form; parse the second column. <!-- vault: perishable; reinforced 2026-08-11; expires when gh-axi changes its capacity output again -->
```

The three tiers are named for their handling, not their subject:

- **pinned** - no clock and no eviction.
  A standing preference or decision that is true until the boss changes it.
- **aging** - stale 30 days after its `reinforced` date.
  A fact about how the fleet or a tool currently behaves: probably still true, worth re-checking before it is trusted again.
- **perishable** - stale 7 days after its `reinforced` date, and MANDATORY a checkable expiry condition after `expires when`.
  A fact tied to a specific moving situation.
  If a finding cannot state a condition a future session could actually check, it is not perishable: file it as aging or pinned instead.
  A perishable entry written without an expiry condition is a defect, not a shortcut.

File-scoped defaults, declared by a legend line in each file's header so the file is self-describing:

- `config/boss.md` and `config/boss-shared.md` default **pinned** - they are the boss's own preferences, and forgetting one is worse than carrying it.
- `config/learnings.md` defaults **aging** - it records how things currently behave, which is exactly the material that rots.

The legend line to write at the top of each of those files (adjust the named default per file):

```
<!-- vault tiers: pinned = no clock; aging = stale 30 days after its reinforced date; perishable = stale 7 days after its reinforced date and carries an expires-when condition. Unmarked entries in this file read as pinned. Each entry carries a trailing HTML comment "vault: <tier>[; reinforced YYYY-MM-DD][; expires when <condition>]". Owner: skills/vault. -->
```

**Reinforcement** resets an entry's `reinforced` date, and it requires evidence from this session that the fact was USED - acted on, relied on for a decision, or re-verified against the live system.
Merely reading the entry during startup or during this sweep NEVER reinforces it.
That is the whole point: a clock that resets on every read measures nothing, and the entries that quietly rot are exactly the ones every session reads and no session uses.

**The decay pass**, run on every sweep before any budget judgment:

1. For each aging and perishable entry, compare today against its `reinforced` date, and check every perishable entry's expiry condition against what is actually true now.
2. Reinforce the entries this session used or re-verified.
3. Retire the rest of the stale ones to the archive.
4. A stale entry whose fact was found to be WRONG is retired as obsolete, and the corrected fact is written as a new entry rather than edited into the retired one.

Stale is a prompt to decide, not an automatic verdict: an aging entry that is plainly still true and still belongs here is reinforced and stays.
What stale forbids is leaving it unexamined for another 30 days.

## Archive, never delete

Stale entries and budget evictions MOVE to `data/memory-archive.md`.
That file is the cold tier: it is never read at session start, never injected into any session's context, and costs nothing until a session deliberately opens it.

Each archived entry keeps its provenance, so a later session can tell where it came from and why it left:

```
- herdr 0.7.5 reports pane cwd on `pane get`. <!-- archived 2026-08-11; from config/learnings.md; reason: aging, last reinforced 2026-06-01, not used since -->
```

The reason names one of: stale (with the tier and last-reinforced date), obsolete (with what proved it wrong), or evicted (over budget, with the date the boss approved the eviction).

Prune always means "move to the cold tier".
A unique fact is never deleted to save space, whether it is stale, obsolete, or evicted.
The only outright deletion is a genuine duplicate whose content already survives, verbatim in substance, in the entry it duplicates.

## Over budget

`config/boss.md`, `config/boss-shared.md`, and `config/learnings.md` are startup memory: every session of this home reads them in full at every start, so their size is a standing cost paid whether or not a session uses them.
When the session-start digest reported one of them over its startup-memory budget, bringing it back under budget is part of this sweep rather than a later chore.
Work in this order and stop as soon as the file is under budget:

1. **Decay.** Run the decay pass above.
   A file that is over budget because it is carrying six months of unreinforced facts is fixed here, and no eviction decision is needed.
2. **Consolidate.** Merge duplicate entries, rewrite a multi-line note down to the durable fact it is really asserting, and retire entries now owned by a more specific destination under `AGENTS.md` section 6.
3. **Propose eviction.** Only if the file is STILL over budget.
   Consigliere does not decide which of the boss's own preferences leave: it proposes.
   Name the candidate entries and the bytes each would free in the report, file ONE durable boss-held backlog item for the decision (`tasks-axi hold <id> --reason "<reason>" --kind captain`), and leave the file over budget until the boss answers.
   An entry leaves startup memory - to the archive, with an `evicted` reason - only after the boss decides.

Never get under budget by dropping a fact that is still true and still belongs here.
If the file cannot fit without losing such a fact, leave it over budget and say so in the report, so the boss can decide between raising the budget and retiring the material.

## Cascade

A `/vault` invoked in the primary home sweeps the whole fleet's memory, not just the primary's.
Capo homes have their own `config/boss-shared.md` and `config/learnings.md`, their own budgets, and their own sessions; without a cascade they are never curated at all and drift uncurated forever.

Run `bin/cs-vault-cascade.sh` AFTER the primary home's own pass is complete.
The script owns the mechanics: it enumerates each registered capo exactly once, reports that home's budget accounting, and resolves how the sweep reaches it.
Its header and `--help` own the exact output, flags, and bounds; do not re-derive them here.
It reports and never writes, sends, or curates anything itself.

Act on each home's resolved route:

- **send** - a live agent holds that home.
  Run the printed `cs-send` command so the capo runs its own `/vault`, which is the only way its own uncaptured session knowledge reaches disk.
  Its reply returns through the ordinary marked-request path (its status or a document pointer), never by reading its chat.
- **curate** - the home has no live agent to ask.
  Consigliere curates that home's memory files in place, under exactly the tier, decay, archive, and budget rules above.
  Only what is already on disk there can be curated; nothing from a dead session is recoverable, and the report must not imply otherwise.
- **exception** - that home could not be evaluated (wedged, unreadable, or ambiguous).
  Report it as not swept, with the reason, and continue.
  The sweep never stops at the first bad home.

Every home is judged against its OWN budget, per file.
Never sum sizes across homes and never let one home's headroom excuse another's overflow.

A capo home's own `/vault` sweeps that home and stops.
It never cascades further; only the primary home cascades.

Nothing here runs on its own: the cascade happens when the boss invokes `/vault` and at no other time.
It adds no notification, no session-start digest section, and no background work.

## Migration of unmarked entries

Existing memory files predate the tier markers, and a bulk rewrite of every entry in one pass is a destructive edit of the boss's own preferences made by an agent that has not read them one at a time.
So migration is incremental and non-destructive:

- An unmarked entry reads as its file's default tier, and behaves exactly as if it carried that marker.
  An unmarked entry in a pinned-by-default file is never stale, so nothing is silently evicted by the migration itself.
- Mark entries as you encounter them - when a sweep classifies a finding against an entry, reinforces it, rewrites it, or retires it - and leave the rest alone.
- Add the legend line to a file the first time this skill writes to it.
- Never rewrite a whole file just to add markers.

The end state is a fully marked file reached one considered entry at a time; there is no migration pass to run and no deadline to meet.

## Scope exclusion: no skill storage

`/vault` must **never** store, create, or edit a skill as a destination for any finding.
There is no "graduate this to a skill" move in this skill's routing.
This is a deliberate, standing exclusion, not an oversight: a vault sweep is a memory-routing operation, not a way to author or mutate skills.
Writing learnings into `skills/` would risk mixing fleet-local material with shared consigliere behavior.
Until a human deliberately scopes a skill change as consigliere repo work, route knowledge about consigliere itself to the shared `AGENTS.md` (or other shared, tracked material) via the pipeline, and fleet-local knowledge to `data/`, never to a skill.

`data/memory-archive.md` is the ONLY cold tier this skill has.
There is no second offload destination: not a skill, not a doc, not a new file invented mid-sweep.
An entry either stays in startup memory or moves to the archive.
If a sweep ever genuinely needs somewhere else for material to live, that is a decision for the boss - raise it as one rather than inventing a destination.
