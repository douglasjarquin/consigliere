# Upstream review

Consigliere was ported from Firstmate at commit `51404137e8c4729670233cc31ff43eeae527b77c` (2026-07-22).
Seed a fresh home's `data/upstream-review.md` with that SHA when none exists:

```
last-reviewed: 51404137e8c4729670233cc31ff43eeae527b77c
```

Mechanism:
- `bin/cs-upstream-log.sh` - read-only; fetches the firstmate checkout (`config/upstream`, default `../firstmate`) and prints `git log --reverse --stat <last-reviewed>..origin/HEAD`.
- `skills/upstream-review` - the editorial triage procedure and relevance table; the only writer of `data/upstream-review.md`.
- Ports are always fresh implementations against consigliere's structure; `git merge`/`cherry-pick` from firstmate is never used.
