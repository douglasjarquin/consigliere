# Telemetry

The single owner of consigliere's optional turn telemetry.
`bin/cs-telemetry-lib.sh` implements every rule stated here and its header owns the API; `bin/cs-telemetry-report.sh --help` owns the report's flags.

Telemetry exists to answer one measurement question with production data rather than intuition: what share of scarce frontier-model usage is attributable to root and capo supervision, and how much of that supervision produces no action at all.
It is measurement only.
It never changes dispatch, wake classification, checkpoint behavior, monitoring, worker lifecycle, model or harness selection, prompts, delivery mode, merge or review behavior, or failure handling.
Nothing in it selects a model, routes a turn, suppresses a wake, or calls a model to classify anything.

## Optional, and off by default

Telemetry is off unless this machine turns it on.
Enable it in the home you want measured:

```
printf 'enabled true\n' > host/telemetry.conf
```

Disable it again by removing that file, or by setting `enabled false`:

```
rm host/telemetry.conf
```

View the report at any time:

```
bin/cs-telemetry-report.sh
bin/cs-telemetry-report.sh --json
```

Delete everything ever collected:

```
rm -rf data/telemetry state/.telemetry-crumbs-* state/.telemetry-cursor-*
```

`bin/cs-doctor.sh` reports telemetry in its CONFIG + HOST section.
Disabled is an ordinary informational line, never a warning or an error.
Enabled reports the resolved storage path.
A malformed explicit config is reported specifically and warns without failing the run.

### host/telemetry.conf

`host/` is machine-local by contract, so telemetry configuration is never portable `config/` material, is never backed up or restored, and is never propagated into a capo home.
A capo enables its own telemetry with its own `host/telemetry.conf`, exactly like every other host-tier fact.

The schema is two whitespace-separated columns per record, the same shape as the other host configs.
Blank lines and lines whose first field begins with `#` are ignored.

```
enabled true
retain_days 30
```

`enabled` is `true` or `false` and is REQUIRED.
`retain_days` is optional, is an integer between 1 and 3650, and defaults to 30.
It is normalized to base 10 as it is parsed, so a value written with a leading zero cannot mean one number to the record sweep and another to the cursor sweep.

The parse is strict on purpose.
An unknown key, a missing or extra field, a duplicate record, a bad value, or a file with no `enabled` record is MALFORMED, which means disabled plus a doctor diagnostic.
There is no partial enable, and a malformed config is never a runtime failure.

## What is collected, and what is not

Telemetry describes the event; it never reproduces the conversation.

Collected: a timestamp, a unique event id, the emitting home, the role (root, capo, ship, scout), the task kind, the project name, the task or capo id, the harness, the model, the effort, the derived purpose, the causing wake kind and the full set of kinds the turn drained, the derived supervision outcome, the turn duration, the harness session identifier, and normalized token counts.

Never collected: boss prompts, worker transcripts, tool output, file contents, environment variables, secrets, credentials, terminal scrollback, branch or PR content, or any free-text summary of a turn.
The usage extraction reads a session transcript but only ever takes numbers, the model name, and the effort level out of it.
There is no option to record a textual summary, because a structured field answers every question this measurement exists for.

## Storage

One append-only JSON Lines file per home, under the disposable machine-local generated tier:

```
data/telemetry/turns.jsonl
```

The path is resolved through the active `CS_HOME`, so each capo home records its own turns in its own file.
`.gitignore` already excludes `data/`, so telemetry is never committed.
The whole tier is disposable: deleting it costs history and nothing else.

One JSON object per line, one line per measurable turn.
Each record is written as a single append below 4000 bytes, which is what keeps two emitters in the same home from interleaving a partial line; an over-cap record is dropped whole rather than truncated.

## Record schema

The schema is versioned from the first record.
Every field except `schema`, `timestamp`, and `event_id` is nullable, so a later addition is a new field rather than a new schema.

```json
{
  "schema": 1,
  "timestamp": "2026-08-08T12:34:56Z",
  "event_id": "0b9c...",
  "role": "capo",
  "kind": "capo",
  "home": "/Users/you/.consigliere/capos/infra",
  "project": "niceuptime",
  "task_id": "infra",
  "harness": "codex",
  "model": "gpt-5.6-sol",
  "effort": "xhigh",
  "purpose": "supervision",
  "wake_kind": "stale",
  "wake_kinds": ["stale", "signal"],
  "outcome": "wait",
  "duration_ms": 1234,
  "session_id": "019fe1ea-df85-7a02-932b-d0ed71bdff54",
  "usage": {
    "input_tokens": 28820,
    "cached_input_tokens": 6912,
    "output_tokens": 5,
    "reasoning_tokens": 0,
    "total_tokens": 28825
  }
}
```

A value that is not authoritatively available is `null`.
No model identity, effort level, or token count is ever inferred, defaulted, or estimated into a record.

## Vocabularies

Role: `root` for the main consigliere's own turns, `capo`, `ship`, `scout`.
The root is not a dispatched capo and never falls into the capo bucket.

Task role and kind come from `state/<id>.meta`, which `bin/cs-spawn.sh` already writes; the wake vocabulary is the durable queue's own, validated by `bin/cs-wake-lib.sh`.
Neither is re-derived or re-classified here.

Purpose: `boss`, `dispatch`, `supervision`, `status`, `decision`, `review`, `recovery`, `implementation`, `research`, `other`.

Supervision outcome, recorded for every turn whose purpose is `supervision`: `wait`, `no_action`, `message_worker`, `dispatch_more`, `technical_intervention`, `recovery_action`, `escalate_up`, `completed`, `unknown`.
`wait` and `no_action` matter most: together they estimate the ceiling of what a cheaper supervision tier could absorb.

Wake provenance: `wake_kind` stays inside the queue's own vocabulary of `signal`, `stale`, `check`, `capo`, and `heartbeat`, plus `checkpoint` for a turn whose only supervision was a bounded foreground checkpoint.
It carries the FIRST kind the turn drained, so supervision counted by wake kind still sums to the supervision turn count.
`wake_kinds` is the additive companion: every distinct kind the turn drained, in drain order, so a turn that drained several stays fully recoverable.
It is null for a turn that drained none.

## Classification is deterministic and free

There is no model call anywhere in this subsystem.
Classification is derived mechanically from control flow: an instrumented script drops a small structured breadcrumb for the current turn, and the turn-end emitter folds those breadcrumbs into one purpose and one outcome, then clears them.
That keeps one owner of the rules and keeps the classification honest, because it describes what actually ran rather than what a turn said about itself.

Breadcrumbs are turn-scoped, live in `state/.telemetry-crumbs-<session>`, and are cleared at each turn end.
Keying them per session is what stops a second window, a read-only helper, or a tooling session started in the repo root from folding and deleting the real supervisor's in-flight breadcrumbs and mis-attributing its supervision turn.
A shell that cannot resolve its own session drops the breadcrumb silently, and a turn end that cannot resolve it folds nothing and still records the turn with a null wake kind.

The `<session>` key is `<pid>-<hash>`, where the pid is the harness process in the dropping shell's ancestry - exactly what `state/.lock` already means by "this session" - and the hash covers that pid together with `cs_pid_identity`, the process start time that makes a recycled pid read as a mismatch.
`bin/cs-session-pid-lib.sh` owns both the ancestry walk and that identity read; `bin/cs-telemetry-lib.sh` owns the derivation of the key from them.
A bare pid would not do, because pids recycle: a session that dropped breadcrumbs and then died without reaching a turn end leaves its file behind, and a later session resolving the same number would fold a dead session's breadcrumbs into its own first turn.
An unresolvable identity yields no key at all rather than a bare-pid fallback, which costs one turn's classification and nothing else.

Two independent guards bound a leftover file, because they fail differently.
The hashed key makes a cross-session collision impossible even while the file survives.
The fold separately ignores and removes any breadcrumb file whose mtime is older than `CS_BUSY_TURN_MAX_SECS` (default 3600, `docs/configuration.md`), which is this repo's existing bound on how long one turn may legitimately run, so no second number can drift from it and no real turn can be truncated.
Whatever still survives both ages out under the same retention sweep as the transcript cursors.

| breadcrumb | dropped by | meaning |
|---|---|---|
| `wake <kind>` | `bin/cs-wake-drain.sh` | one drained wake row of that kind |
| `checkpoint` | `bin/cs-watch-checkpoint.sh` | a bounded foreground supervision checkpoint ran |
| `spawn <kind>` | `bin/cs-spawn.sh` | a soldier or capo was dispatched |
| `steer` | `bin/cs-send.sh` | a direct report was messaged, and delivery was confirmed |
| `merge` | `bin/cs-pr-merge.sh`, `bin/cs-merge-local.sh` | work actually landed |
| `teardown` | `bin/cs-teardown.sh` | a task was cleaned up |
| `promote` | `bin/cs-promote.sh` | a scout was promoted to ship |

### The folding rules

These rules are the ROOT and CAPO turn-end path.
A worker turn does not fold at all: a soldier records no breadcrumbs and supervises nothing, so its purpose follows directly from the task kind in `state/<id>.meta` - `kind=ship` is `implementation`, `kind=scout` is `research`, and anything else is `unknown` - and it carries no supervision outcome.
That is what makes the implementation-versus-supervision comparison readable straight off the `purpose` column.

Let `W` be the set of drained wake kinds, `C` whether a checkpoint ran, and `A` the set of action breadcrumbs (`spawn`, `steer`, `merge`, `teardown`, `promote`).

Purpose, first match wins:

1. `W` non-empty or `C` -> `supervision`, because monitoring is what caused the turn.
2. `spawn` in `A` -> `dispatch`.
3. `merge`, `teardown`, or `promote` in `A` -> `review`.
4. `steer` in `A` -> `supervision`.
5. role is `root` -> `boss`.
6. otherwise -> `unknown`.

Outcome, recorded only when purpose is `supervision`, first match wins:

1. `stale` in `W` and `A` non-empty -> `recovery_action`, a stale worker that genuinely needed intervention.
2. `spawn` in `A` -> `dispatch_more`.
3. `merge`, `teardown`, or `promote` in `A` -> `completed`.
4. `steer` in `A` -> `message_worker`.
5. `W` non-empty -> `no_action`, meaning wakes were reviewed and nothing was done.
6. `C` with `W` empty -> `wait`, meaning the worker is still working and monitoring continued.
7. otherwise -> `unknown`.

So in this dataset `wait` means precisely "a checkpoint ran, no wake was drained, and no action was taken", and `no_action` means precisely "at least one wake was drained and no action was taken".
Neither is an opinion about whether the turn was useful; both are statements about what ran.

Purpose rule 5 is the one inference in the table, and it rests on the operating contract rather than on a guess about content: `AGENTS.md` section 8 requires every wake-handling turn to drain the queue first and to hold exactly one live checkpoint while work is under way, so a root turn that ran neither, and dispatched, steered, merged, tore down, or promoted nothing, supervised nothing.
A capo turn with the same emptiness stays `unknown`, because a capo is idle by default and its turns arrive as work routed from the main home.

`escalate_up` and `technical_intervention` stay in the vocabulary but have no deterministic mechanical source, so schema 1 never emits them.
The same applies to the `status`, `decision`, `recovery`, and `other` purposes.
Preferring `unknown` over a guess is deliberate: these numbers will be acted on, and bad telemetry is worse than missing telemetry.

## Instrumentation points

| point | records | why here |
|---|---|---|
| `bin/cs-turnend-guard.sh` | one record per root or capo turn | the harness Stop hook already fires here for the main home and every capo home, it is already scoped to a primary checkout, and it is where both harnesses expose usage data |
| the worker turn-end wiring in `bin/cs-harness-lib.sh` | one record per ship or scout turn | the only per-turn boundary a soldier has |
| `bin/cs-wake-drain.sh` | breadcrumb | the one owner of draining, so wake provenance has a single source |
| `bin/cs-watch-checkpoint.sh` | breadcrumb | the one supervision wait shape |
| `bin/cs-spawn.sh` | breadcrumb | dispatch attribution, on the turn that dispatched |
| `bin/cs-send.sh`, `bin/cs-pr-merge.sh`, `bin/cs-merge-local.sh`, `bin/cs-teardown.sh`, `bin/cs-promote.sh` | breadcrumb | the actions that separate a supervision turn that did something from one that did not |

The worker wiring keeps the turn-end `touch` first and separate.
On codex the telemetry call is appended to the `notify` command after `; `, never `&& `, so the touch runs first and unconditionally.
On claude it is a SEPARATE second Stop hook command, so the touch keeps its own process and its own exit status.
`bin/cs-spawn.sh` resolves the telemetry call at spawn time, so a soldier launched while telemetry is off carries a byte-identical launch line and settings file.

## Harness usage data

Verified live on 2026-08-08 against codex-cli 0.147.0 and claude 2.1.226; `docs/codex.md` and `docs/claude.md` record the exact payloads.
Both harnesses hand the Stop hook a `transcript_path`, and neither reports a per-turn total directly, so the emitter reads the window between this turn end and the previous one from a per-session byte cursor (`state/.telemetry-cursor-<session>`) and sums the usage inside it.

The recorded `harness` for a root or capo turn is derived from the Stop payload's own shape, because the payload is the only authority on what actually ran the turn being measured: a codex payload carries `turn_id`, a claude payload carries `prompt_id`, and that pair is the discriminator.
`host/harness.conf` is deliberately NOT consulted here - it pins what consigliere dispatches with, not what produced this turn, so a home whose pin disagrees with the running session would otherwise record a confident wrong harness and then feed the transcript to the wrong parser.
A payload carrying both fields, neither, or nothing at all is ambiguous, and an ambiguous harness is recorded as `null` with usage extraction skipped.
A worker turn is different: its harness comes from the authoritative `state/<id>.meta` that `bin/cs-spawn.sh` wrote.

Codex, from the rollout under `~/.codex/sessions/`:

- `input_tokens`, `cached_input_tokens`, `output_tokens`, `reasoning_tokens` (its `reasoning_output_tokens`), and `total_tokens`, summed from every `event_msg`/`token_count` record's `info.last_token_usage` in the window.
- `duration_ms` from the turn's own `event_msg`/`task_complete` record.
- `model` from the Stop payload, `effort` from the rollout's `turn_context`.

Claude, from the transcript under `~/.claude/projects/`:

- `input_tokens`, `cached_input_tokens`, `output_tokens`, and `total_tokens` from each assistant message's `message.usage`.
- `reasoning_tokens` is always null, because claude counts thinking tokens inside `output_tokens` and does not report them separately.
- `duration_ms` as the wall span of the window's own record timestamps.
- `model` from the transcript, `effort` from the Stop payload's `effort.level`.

### Where attribution is necessarily approximate

- **Claude input normalization.** Anthropic reports `input_tokens` EXCLUDING cache reads and cache writes, while codex reports an input total with the cached part as a subset. The recorded `input_tokens` is therefore `input + cache_creation + cache_read`, so both harnesses mean the same thing in one dataset. Read `cached_input_tokens` alongside it before drawing a cost conclusion, since a cached input token is far cheaper than a fresh one.
- **Claude streaming snapshots.** The transcript records several snapshots of one assistant message under the same `message.id`; usage is deduplicated by that id and only the last snapshot of each is summed. Without that, a turn's tokens would be multiplied severalfold.
- **Transcript records that land after the Stop hook.** A record written after the hook runs falls into the NEXT turn's window. Per-turn figures therefore carry a small lag; period totals do not.
- **A cold cursor.** The first turn measured in an existing session has no previous cursor, so it is credited with the whole transcript so far. Only the first turn per session is affected, and only when telemetry was enabled mid-session.
- **Codex worker turns.** Codex's `notify` program receives an argument rather than the Stop payload, so a codex ship or scout soldier's turns are recorded with role, kind, project, harness, model, effort, and purpose, but with `null` tokens and `null` duration. Claude workers get full usage, because their Stop hook does receive the payload.
- **Headless scouts.** A headless scout's turn end is process exit and its launch line already owns the terminal status append, so it is deliberately not instrumented.
- **`model` and `effort` for a capo.** A capo's dispatched model lives in the PARENT home's `state/<id>.meta`, not in the capo's own home, so a capo turn takes them from its own harness session instead. They are null when the harness does not expose them.

## Retention

`retain_days` bounds the file: records older than that are dropped, and the per-session transcript cursors and breadcrumb files age out on the same schedule.
Retention runs at the turn-end boundary that already exists, at most once per 24 hours per home, behind a non-blocking lock.
It can never block, delay, or interfere with supervision: a held lock, a missing `jq`, or an unwritable directory skips silently and the next turn end tries again.
The lock is released by a trap on the subshell that holds it, and a lock directory older than one prune interval is reclaimed on the next attempt, so a hard kill mid-prune cannot wedge retention permanently while a genuinely held fresh lock is still skipped.
The rewrite is a compare-and-swap on file size, so a record another emitter appended while the file was being filtered is never silently dropped; a detected append abandons that rewrite and the next interval retries.

## Failure policy

Every telemetry call site swallows every failure.
An unwritable path, a malformed config, an unparseable usage payload, a missing `jq`, or any other telemetry error leaves the caller's exit status, stdout, stderr, and side effects exactly as they were without telemetry.
`jq` is required for serialization and usage extraction, and it is already a required consigliere dependency; without it telemetry is a silent no-op that the doctor reports.

The cost is one short shell call at each instrumented boundary: a breadcrumb is a single line append, and a turn end adds a bounded transcript read plus a few `jq` invocations.
That work runs inside the turn-end hook, after the turn-end signal has already been written, and the transcript window it reads is capped, so it cannot grow with session length.
With telemetry disabled every call site short-circuits on the absent `host/telemetry.conf`, and a soldier launched while it is disabled carries no telemetry command at all.

`tests/cs-telemetry-invariants.test.sh` is the regression guard for the prime invariant.
It runs the turn-end guard, the wake drain, and the bounded checkpoint twice - once with telemetry off, once with it on - and fails on any difference in exit status or output, while separately asserting that telemetry really did record something so an equal-output result can never be a false green.
It also proves the turn-end signal still lands when the telemetry command cannot run at all.

`CS_TELEMETRY_DISABLE=1` is a test and escape seam, unset in production, that forces telemetry off regardless of the config; `tests/lib.sh` pins it for every suite so an uninstrumented test can never append synthetic turns to a real dataset.

## Reading the report

`bin/cs-telemetry-report.sh` is strictly read-only: it never mutates telemetry, state, or supervision, and it never triggers retention.
An absent or empty telemetry file is a clean, informative, zero-exit outcome.

It reports the period, the total recorded turns, turns by role, by purpose, by role and purpose, supervision turns by causing wake, and supervision turns by outcome, with the same breakdowns by tokens wherever usage exists.
`--json` carries the same aggregates for later analysis and replay.

Every figure in the closing block is an ESTIMATE and an upper bound on what a cheaper supervision tier could absorb, never a guaranteed saving.
`capo share of frontier usage` is the cheap-capo opportunity: the share of measured tokens that pointing `kind=capo` at a cheaper model through `config/dispatch-policy.conf` would move, before anything more complicated is built.
Read it beside `turns recorded, N carrying token usage`, because a token share computed over a partly instrumented period covers that subset only.
