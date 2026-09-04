# Context budget baseline (issue #151, Phase 0)

Recorded 2026-09-02 against `main` at commit `3c64760` (last commit to touch `AGENTS.md` before this change), on this machine (bash 5.3.15, macOS/Darwin 25.6.0).

## Kernel size before this change

```text
$ wc -c AGENTS.md
52885 AGENTS.md
$ wc -l AGENTS.md
526 AGENTS.md
```

Rough token estimate (chars/4, a documented deterministic proxy, not a tokenizer call): ~13221 tokens.

## Kernel size after Phase 1 (this change)

```text
$ wc -c AGENTS.md
10227 AGENTS.md
$ wc -l AGENTS.md
120 AGENTS.md
```

~2557 tokens by the same chars/4 proxy - roughly an 81% byte reduction, under the issue's 10 KB hard target.

## Startup script size

```text
$ wc -l bin/cs-session-start.sh
965 bin/cs-session-start.sh
```

The issue's own text cites "roughly 70 KB / 578 lines" for this script; it has grown to 965 lines since that estimate was written, ahead of any Phase 3 work. Recording the true current figure here so Phase 3 measures against reality, not the issue's original (stale) number.

## Repository content moved out of the kernel

Extracted into three new agent-only skills and two extended docs, with only a one-line trigger left in `AGENTS.md`:

- `skills/task-lifecycle/SKILL.md` - former section 7 (task lifecycle) and section 11 (soldier briefs).
- `skills/escalation-style/SKILL.md` - former section 9 (escalation and boss etiquette): the translation table and reach-the-boss list.
- `skills/backlog-contract/SKILL.md` - former section 10 (backlog contract).
- `skills/project-management/SKILL.md` - gained a "Knowledge routing" section (former section 6 body).
- `docs/configuration.md` - gained a "Complete home layout" section (former section 2's full ASCII tree).
- `docs/supervision.md` - gained "Turn handling by wake type" and "Self-activation" sections (former section 8 body).

Section 4 (Harness) was folded into the kernel's intro paragraph rather than extracted, since its three sentences were already at kernel-appropriate size.
Every cross-reference to a renumbered `AGENTS.md` section across `skills/`, `docs/`, and `bin/` comments was updated to match (verified with `tests/skill-inventory.test.sh`, which passes); `docs/upstream-review.md`'s dated ledger entries were left untouched as historical record, since they describe what was true at the time each entry was written.

## Worker brief and pack sizes (Phase 2, `bin/cs-context-pack.sh --list`)

Every role/workflow/harness combination, measured by `bin/cs-context-budget.sh` against the merged Phase 2 composer:

| role | workflow | codex | claude | grok | cursor |
|---|---|---|---|---|---|
| root | none | 10227 | 10227 | 10227 | 10227 |
| scout | report-only | 5447 | 5449 | 5445 | 5449 |
| ship | made | 10329 | 10333 | 10325 | 10333 |
| ship | direct-PR | 8118 | 8122 | 8114 | 8122 |
| ship | local-only | 7038 | 7039 | 7037 | 7039 |
| capo | none | 6705 | 6706 | 6704 | 6706 |

Bytes, `ultrawork` exec-mode where applicable. Root's pack is the kernel itself, so it is identical across harnesses by construction; the small ship/scout/capo variance across harnesses (a handful of bytes) comes from `bin/cs-harness-lib.sh`'s per-harness resume-command/skill-syntax text baked into the rendered brief. A `plan-first` ship pack additionally varies by harness by ~40-60 bytes (each harness names its own plan/start-work skill invocation) - see `tests/cs-context-pack.test.sh`.

## Startup fixture sizes (Phase 3+4, `bin/cs-context-budget.sh`)

| fixture | tasks | bytes | vs. 20480-byte hard ceiling | vs. 12288-byte preferred target |
|---|---|---|---|---|
| empty | 0 | 7934 | under | under |
| five (representative) | 5 | 10290 | under | under |
| pathological | 200 | 13629 | under | over |

The pathological fixture is the concrete proof the Phase 3 task-inventory cap (`CS_SESSION_START_TASK_LIMIT`, default 15) holds: 200 seeded tasks still produce a 13629-byte digest, comfortably under the 20 KB hard ceiling, because only the first 15 print in full and the rest collapse to one remainder line. It is over the 12 KB preferred target, which is expected and reported (not enforced) - a genuinely large fleet is exactly the case the preferred/hard distinction exists for.

These three fixtures, plus every pack composition above, are asserted directly by `tests/cs-context-budget.test.sh` (`CI=true bin/cs-lint.sh` and `bin/cs-test-run.sh --portable` both run it in CI), so a future change that regresses the kernel or any startup fixture past its hard ceiling fails the PR rather than landing silently.
