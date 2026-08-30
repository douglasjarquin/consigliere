# Authoritative Linux daemon gate at exact source head

Date: 2026-08-30.

Target source head: `7c54c782552f3ee5a09ddee35735e90cba1b9339` on `revival/v0-local-codex`.

Base: `24ffea8fa1f5bc983fb5965efab0a89b6116f05b` from `origin/rewrite-in-elixer`.

The command was:

```text
docker run --rm -v "$PWD":/workspace -w /workspace/runner/cs-runner elixir:1.20-otp-29 sh -lc 'set -o pipefail; apt-get update -qq && apt-get install -y -qq golang-go >/dev/null && go version && go build -o /workspace/daemon/priv/cs-runner . && cd /workspace/daemon && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test --no-color --seed 0 && MIX_ENV=test mix test --no-color --seed 0 && MIX_ENV=test mix test --no-color --seed 0'
```

The container built Go `1.26.6`.

Formatting passed.

Warnings-as-errors compilation passed.

Each of the three consecutive seed-0 runs returned `496 passed (1 doctest, 495 tests)` with exit code `0`.

The suite includes the current package-runner compatibility, generation identity, bounded observer, process-start fingerprint, process-group membership, reconciler cleanup, and exact-SHA recovery coverage.

The output receipt is bounded and contains no credentials, prompts, transcripts, or raw canary data.

Verdict: PASS.
