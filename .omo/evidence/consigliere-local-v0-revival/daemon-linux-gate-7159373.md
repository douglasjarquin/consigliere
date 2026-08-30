# Linux daemon gate at exact source head

Date: 2026-08-30.

Source: `71593738cf6aae723c9208743405fa12a9dc7a03` on `revival/v0-local-codex`.

The gate used the `elixir:1.20-otp-29` container, installed Go `1.26.6`, built the checked-in runner into `daemon/priv/cs-runner`, checked formatting, compiled with warnings as errors, and ran the complete daemon test suite.

The bounded command was:

```text
docker run --rm -v "$PWD":/workspace -w /workspace/runner/cs-runner elixir:1.20-otp-29 sh -lc 'set -e; apt-get update -qq && apt-get install -y -qq golang-go >/dev/null && go version && go build -o /workspace/daemon/priv/cs-runner . && cd /workspace/daemon && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix compile --warnings-as-errors && for run in 1 2 3; do MIX_ENV=test mix test --no-color --seed 0; done'
```

The three sequential runs each returned `Result: 491 passed (1 doctest, 490 tests)` and exit code `0`.

This is the authoritative Linux daemon receipt for the final runtime source.
