# Native macOS full-suite observation

Target runtime commit: `42933d103da9171c76b1564888e0d6557291fb5d`.

Command: `cd daemon && PATH="/opt/homebrew/opt/erlang/bin:$PATH" mix format --check-formatted && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test --no-color --seed 0`.

The native macOS run reported `473/482` passing tests and nine environment-sensitive failures.

The failures were two stale `boss.sock` probe assertions, two runner environment cases exceeding macOS's short Unix-domain socket path limit, two Project path assertions comparing `/var` with canonical `/private/var`, and three reconciler process-group fixture or cleanup observations.

The package and installed macOS lifecycle were tested separately with a short fresh home and passed all required lifecycle assertions.

The Linux CI-shaped gate with actual Go `1.26.6` passed the complete daemon suite three consecutive times and remains the authoritative cross-platform release gate.

No credentials, raw logs, database contents, or process identifiers are retained in this summary.
