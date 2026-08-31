# Review finding 7 - canonical invalid identity

Head before this correction: f2ca902026b74344b28a6941b789ff30cc8688f2.

RED: `PATH="/opt/homebrew/Cellar/erlang/29.0.5/bin:$PATH" MIX_ENV=test mix test test/consigliere/command_receipts_test.exs --no-color` returned `Result: 11/12 passed` because distinct invalid payloads reused the sanitized validation-error hash.

GREEN: the focused command returned `Result: 13 passed` after hashing the original invalid payload and rejecting canonical-hash failures instead of accepting them.

Covered outcomes: same-key distinct invalid payloads return `idempotency_conflict`; a canonical-hash failure returns `canonical_request_invalid` before a receipt is claimed.

No secrets, credentials, prompt text, or raw unbounded output are retained.
