# Native macOS daemon gate at exact source head

Date: 2026-08-30.

Source: `71593738cf6aae723c9208743405fa12a9dc7a03` on `revival/v0-local-codex`.

The native command checked formatting, compiled with warnings as errors, and ran the complete daemon suite:

```text
cd daemon
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test --no-color --seed 0
```

The command exited `0` and returned `Result: 491 passed (1 doctest, 490 tests)`.

The separate package-only lifecycle receipt records the macOS socket, process identity, restart, repeated-stop, and cleanup proof.
