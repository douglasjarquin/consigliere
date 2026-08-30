# Native macOS full-suite observation

Target runtime commit: `bf2dce60b52447e9075f05f135c4c36ccb2722ae`.

Command: `cd daemon && PATH="/opt/homebrew/opt/erlang/bin:$PATH" mix deps.get && mix format --check-formatted && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test --seed 0`.

The native macOS run reported `463/473` passing tests and ten environment-sensitive failures.

The failures were two stale `boss.sock` probe assertions, two runner environment cases exceeding macOS's short Unix-domain socket path limit, two Project path assertions comparing `/var` with canonical `/private/var`, three reconciler process-group fixture or cleanup observations, and one runner report fixture that raced shared test-runtime cleanup.

The package and installed macOS lifecycle were tested separately with a short fresh home and passed all required lifecycle assertions.

The Linux CI-shaped gate with actual Go `1.26.6` passed the complete daemon suite three consecutive times and remains the authoritative cross-platform release gate.

No credentials, raw logs, database contents, or process identifiers are retained in this summary.
