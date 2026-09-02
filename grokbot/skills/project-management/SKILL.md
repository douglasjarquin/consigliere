---
name: Project management
description: Use at Grok Ship intake and whenever work is handed to a soldier.
---

# Project management

A local sqlite database is the factory backlog. Chat is not the source of truth.

## Database path

On the shared Grok Bot computer:

`/home/box/agent-data/grok-ship/factory.db`

Create the parent directory if needed. Same path every time. Do not invent a second database.
Scout reports live beside it in `/home/box/agent-data/grok-ship/reports/`, one file per task id.

## Schema

Canonical schema: see `schema.sql` in this directory.

`projects.repos` is a JSON array of repo slugs or URLs. `projects.source_control` is `github`, `gitlab`, `bitbucket`, or `origin`.

`tasks.kind` is `scout`, `ship`, or `decision`. Do not add `triage`.
`tasks.status` is `queued`, `underway`, `blocked`, `done`, or `cancelled`.
`tasks.result` is the outcome pointer: scout report path, or ship PR URL.
`gate_kind` is optional: `after-task`, `at-time`, or `boss`.

The schema is deliberately minimal: enough to route work and find its results. Do not add tables speculatively.

## Setup

If `factory.db` does not exist, create it and run the schema. If it exists, do not migrate inventively. Report the path to Consigliere.

## Intake

Consigliere writes a task row before handing factory work off. Reuse the task id in the soldier message. A good `prompt` states the goal, acceptance criteria, and constraints - enough to act on without coming back for basics.

Triage wakes stay in chat or cron, not factory.db. Do not write a factory.db row for a standing wake or on-demand "triage now". Do not add kind=triage. Do not file those as scout or ship.

If a project row already maps that repo to a soldier, reuse that soldier. Do not overwrite crewmate_id. Do not insert a second row for the same repo.

If the work belongs to a repo that has no project row, insert one row: sign on from `/home/box/agent-data/grok-ship/pack/GROK_BOT_TRIAGE.md` when the boss asked for triage (factory addendum included), otherwise from the soldier template (`/home/box/agent-data/grok-ship/pack/GROK_BOT_SOLDIER.md`). Record crewmate_id plus repos plus source_control. Do not route factory scout/ship to a second bot.

Non-software work files under the reserved `default` project row (repos `[]`, no source_control); create that row on first use.

## Promotion

When the boss authorizes implementation after a scout, do not open a duplicate task: flip the same row's kind to ship and hand it back to the soldier with the scout report as context. The ship flow then applies unchanged.

## Updates

The soldier updates `status`, `branch`, `result`, and `updated_at` as it goes. Done means `result` holds the pointer: scout report path, or ship PR URL.

## Do not

- Do not keep the factory backlog only in chat
- Do not write a factory.db row for a triage wake
- Do not add kind=triage
- Do not file on-demand "triage now" as scout or ship
- Do not create one Consigliere per project
- Do not assume GitHub when recording `source_control`
- Do not add a role column
- Do not invent a second mapping table
- Do not overwrite crewmate_id
- Do not insert a second projects row for the same repo
