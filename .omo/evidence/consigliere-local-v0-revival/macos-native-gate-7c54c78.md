# Native macOS daemon gate at exact source head

Date: 2026-08-30.

Target source head: `7c54c782552f3ee5a09ddee35735e90cba1b9339` on `revival/v0-local-codex`.

The command was:

```text
PATH="/opt/homebrew/opt/erlang/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH" sh -c 'cd daemon && mix format --check-formatted && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test --no-color --seed 0'
```

Formatting passed.

Warnings-as-errors compilation passed.

The complete native suite returned `496 passed (1 doctest, 495 tests)` with exit code `0`.

The run exercised the actual macOS native process and socket helpers rather than the Linux container substitutes.

The output receipt is bounded and contains no credentials, prompts, transcripts, or raw canary data.

Verdict: PASS.
