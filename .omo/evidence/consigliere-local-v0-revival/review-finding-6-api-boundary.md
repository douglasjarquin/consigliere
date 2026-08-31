# Review finding 6 - API protocol boundary

Head before this correction: 981418c5ee5b0ad645db508ea912732fca7cba5b.

RED: the new envelope regression failed because a list-valued correlation id was accepted and echoed in a success response.

GREEN: `PATH="/opt/homebrew/Cellar/erlang/29.0.5/bin:$PATH" MIX_ENV=test mix test test/consigliere/api_protocol_test.exs test/consigliere/api_cli_ops_test.exs --no-color` returned `Result: 20 passed`.

The API now validates correlation id, operation, payload shape, and the complete read-operation registry before dispatch, and returns a bounded protocol response at the final exception boundary.

Existing advisory log sanitization remains in force, so captured lines and private paths are not part of the authorized or advisory response surface.
