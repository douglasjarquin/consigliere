# Knowledge placement

Where a new fact belongs in this repo, and the review checks that keep `AGENTS.md` from absorbing conditional detail.

## Sub-features

- decision tree: every-session facts stay in `AGENTS.md`; situation-triggered procedure goes to a skill; reference and verified-facts go to `docs/`; exact flags, commands, and paths live in the script header plus `--help`.
- one-owner: state a contract in full exactly once; every other mention is a one-line cross-reference.
- gate-agent scope: Made gate agents must not load this repo's fleet-supervisor identity.
- tracked Markdown style: one full sentence per line, plain dash, never an em dash, never an agent co-author.

## How to get to it (user POV)

Anyone changing consigliere's shared tracked material, including a reviewer on a Made run, has to decide where a new sentence lives before writing it.
The boss never sees this tree; they see the resulting docs, skills, and scripts stay coherent.

## Driving it

- Read `skills/consigliere-coding-guidelines/SKILL.md` before changing documentation or any other shared tracked material.
- That skill owns the decision tree, the inline-stub pattern, size discipline, trigger hygiene, and repo style rules.
- `AGENTS.md` section 1 is only the load trigger plus the safety boundaries that must survive with no skill loaded.
- Verified-facts docs (`docs/herdr.md`, `docs/codex.md`, `docs/claude.md`, `docs/grok.md`, `docs/cursor.md`, and siblings) record date, version, exact commands, and exact output, never an assumption.

## Gotchas

- Made has no `document.instructions` field; this file is the review-guide home for the policy that used to live in `.no-mistakes.yaml`.
- Do not invent a `document.rules` path pattern.
- `AGENTS.md` is paid by every fleet session on every turn, so route conditional or reference detail out rather than appending.
- `.made.yaml` sets `disable_project_settings: true` so a review, fix, document, test, lint, PR, rebase, or CI agent cannot take the session lock or dispatch work.
