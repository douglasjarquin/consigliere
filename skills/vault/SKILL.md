---
name: vault
description: Put the session's durable knowledge in the vault - sweep this conversation for anything worth keeping and file it to disk before a context reset. Use when the boss invokes /vault (e.g. "/vault", "put that in the vault", "vault what you've learned", and the retired "/stow" phrasing), before a session reset or context compaction, or periodically to keep operational memory current.
user-invocable: true
---

# vault

Sweep this session for durable knowledge that only exists in conversation right now, and write it to the disk locations consigliere already prints in the next session-start context digest.
The goal is a session that is safe to reset or destroy because everything durable has already been captured.

## What it does

1. **Sweep the session for uncaptured durable knowledge.**
   Read back over this conversation and look for:
   - Operational learnings: fleet-local facts and gotchas discovered while operating consigliere (a script's sharp edge, a herdr/codex/claude quirk, a recurring false alarm and its real cause).
   - Boss preferences expressed in passing: a working-style or approval preference the boss stated conversationally rather than through the destination selected by AGENTS.md's knowledge-routing table.
   - Project-intrinsic facts discovered: build, test, release, or architecture facts about a project that belong in that project's own `AGENTS.md`.
   - Decisions made: a standing choice the boss made this session that should outlive it.
   - Undone next steps: anything left open that has not yet been filed as backlog work.

2. **Route each finding using AGENTS.md's knowledge-routing table.**
   AGENTS.md (section 6, "Project and knowledge management") is the single source of truth for where each kind of knowledge belongs.
   Read that table and route each finding there instead of re-deriving the mapping here.

3. **Write within consigliere's existing write boundaries.**
   This skill does not grant any new write permission; it only prompts consigliere to use the boundaries that already exist (AGENTS.md section 1):
   - Boss preferences and fleet-local operational facts: hand-write directly to the destination selected by AGENTS.md's knowledge-routing table, using inspect-then-update every time.
     Before writing, inspect the destination, find the existing bullet or section the finding duplicates or supersedes, and rewrite it in place rather than adding a new trailing entry.
     `data/learnings.md` may not exist yet; create it on first local learning, in the same dated, evidence-backed, curated style as `data/boss.md`.
   - Project-intrinsic knowledge: never hand-write a project's `AGENTS.md`.
     Route it through a normal ship task so a soldier records it via `bin/cs-ensure-agents-md.sh` and commits it through that project's delivery pipeline, exactly as section 6 describes.
     If the fleet is live, delegate this to a soldier rather than doing it inline.
   - Knowledge about consigliere itself: this repo's own `AGENTS.md` (or other shared, tracked material), shipped through the normal branch -> no-mistakes -> PR -> boss-merge pipeline for this repo (section 1), never hand-committed straight to `main`.
   - Task-scoped notes: inspect the relevant backlog item with `tasks-axi show <id> --full`, judge whether the new note is new, duplicate, superseding, or obsolete, then write a considered replacement body with `tasks-axi update <id> --body-file <path>`.
     When the replacement intentionally supersedes prior state that should remain recoverable, add `--archive-body` to that update command so the prior body stays recoverable without copying it into the replacement.
     Never append.
     If hand-editing `data/backlog.md` per the active backend, make the same inspect-then-update edit in place.
   - Undone next steps: file each as a queued backlog item (section 10), with `blocked-by` recorded if it genuinely depends on something else.

4. **Curate with inspect-then-update.**
   Every write starts by reading the current destination and deciding how the finding changes what is already there.
   Use this checklist before writing:
   - Which existing bullet, section, or task body does this supersede?
   - Can this be a one-sentence rewrite instead of a new entry?
   - Should an older bullet or note be deleted, retired, or archived because it is now obsolete?
   When a finding overlaps or supersedes something already on disk, rewrite or prune the existing entry instead of piling on a new one.
   Graduation moves are limited to exactly three: promote a learning to the shared `AGENTS.md` via PR, fold it into the boss-preference destination selected by AGENTS.md, or delete a stale entry.
   Do not invent other graduation paths.

   `data/boss.md`, `data/boss-shared.md`, and `data/learnings.md` are startup memory: every session of this home reads them in full at every start, so their size is a standing cost paid whether or not a session uses them.
   When the session-start digest reported one of them over its startup-memory budget, bringing it back under budget is part of this sweep rather than a later chore.
   Consolidate by merging duplicate entries, rewriting a multi-line note down to the durable fact it is really asserting, and deleting entries that are obsolete or now owned by a more specific destination under `AGENTS.md` section 6.
   Never get under budget by dropping a fact that is still true and still belongs here.
   If the file cannot fit without losing such a fact, leave it over budget and say so in the report, so the boss can decide between raising the budget and retiring the material.

5. **Report to the boss.**
   Summarize, in plain outcome language (section 9): what went into the vault and where, what was filed to the backlog, and whether the session is now safe to reset or destroy - i.e. whether every durable finding from this sweep now lives on disk rather than only in this conversation.
   If something could not be captured yet (for example, project-intrinsic knowledge waiting on a soldier to land it), say so explicitly rather than reporting the session fully safe.

## Scope exclusion: no skill storage

`/vault` must **never** store, create, or edit a skill as a destination for any finding.
There is no "graduate this to a skill" move in this skill's routing.
This is a deliberate, standing exclusion, not an oversight: a vault sweep is a memory-routing operation, not a way to author or mutate skills.
Writing learnings into `skills/` would risk mixing fleet-local material with shared consigliere behavior.
Until a human deliberately scopes a skill change as consigliere repo work, route knowledge about consigliere itself to the shared `AGENTS.md` (or other shared, tracked material) via the pipeline, and fleet-local knowledge to `data/`, never to a skill.
