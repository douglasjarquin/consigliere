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

## What Phase 0's fixture/canary requirements do not yet have

This baseline covers kernel and script byte/line counts only.
The issue's Phase 0 checklist also asks for captured startup output across empty/ordinary/pathological fixture homes and current worker-brief sizes by role/delivery-mode/harness.
Those require either a disposable throwaway `CS_HOME` fixture or Phase 2/3 tooling (the pack composer and bounded-startup renderer this issue also asks for) to produce comparable "after" numbers; recording only the "before" halves of those specific measurements here would not be a fair baseline, so they are deferred to land alongside the Phase 2/3 work that makes an apples-to-apples comparison possible.
