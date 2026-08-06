# Upstream review

Consigliere was ported from Firstmate at commit `51404137e8c4729670233cc31ff43eeae527b77c` (2026-07-22).
The review ledger is the tracked file `docs/upstream-review.md`; it versions with the repo, so every home and capo receives it by fast-forward and no per-home seeding exists.
If the ledger were ever absent, seed its first line with the port baseline through the ordinary PR path:

```
last-reviewed: 51404137e8c4729670233cc31ff43eeae527b77c
```

Mechanism:
- `bin/cs-upstream-log.sh` - read-only; fetches the firstmate checkout (`config/upstream`, default `../firstmate`) and prints `git log --reverse --stat <last-reviewed>..origin/HEAD`.
- `skills/upstream-review` - the editorial triage procedure and relevance table; the only writer of `docs/upstream-review.md`, always through a branch, a PR, and the boss's merge.
- Ports are always fresh implementations against consigliere's structure; `git merge`/`cherry-pick` from firstmate is never used.
