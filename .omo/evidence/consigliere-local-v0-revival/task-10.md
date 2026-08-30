# Task 10 evidence

## Scope

Task #10 is the plan's issue #135, bounded API, harness-event, log, and usage data.

The implementation commit is 336a1c1b348068f411541c01d29c774c145c4015.

The task commit includes the centralized Elixir and Go V0 limits, pre-decode JSON scanning, bounded API frame accumulation, request-count and idle limits, typed acknowledgements, strict event metadata, event payload validation and redaction, bounded head-and-tail capture, bounded usage rows, runner frame schemas, and the typed cs doctor storage diagnostic.

## Tests-first record

RED was established with the new limits and capture tests before their modules existed.

The RED run reported 0/5 passed with undefined Consigliere.V0.Limits and Consigliere.Harness.Capture functions.

GREEN was then established with the implementation and the focused tests.

## Automated verification

Command:

    docker run --rm -v "$PWD:/repo" -w /repo/daemon elixir:1.20-otp-29 sh -lc 'mix local.hex --force >/dev/null && mix deps.get >/dev/null && mix format --check-formatted <task-10-files> && MIX_ENV=test mix test test/consigliere/api_protocol_test.exs test/consigliere/api_socket_test.exs test/consigliere/api_cli_ops_test.exs test/consigliere/harness/events_test.exs --seed 0'

Bounded result: 32 passed.

The live socket test sent a frame above 1,048,576 bytes and observed a typed frame_too_large and rejected response.

Command:

    cd runner/cs-runner && go test ./...

Bounded result: ok consigliere/cs-runner (cached).

The Go suite also covers malformed, oversized, replayed, identity-mismatched, out-of-sequence, and unsafe control frames.

## Manual terminal QA

Command:

    docker run --rm -v "$PWD:/repo" -w /repo/daemon elixir:1.20-otp-29 sh -lc 'mix local.hex --force >/dev/null && mix deps.get >/dev/null && mix run --no-start /repo/.tmp/task10_manual.exs'

Observed output:

    TASK10_MANUAL bytes=8388608 bounded=true marker=true secret_redacted=true

The temporary driver was moved to the macOS Trash after the run.

## Adversarial coverage

- Malformed JSON was rejected as a stable invalid response.
- Frames above the byte limit were rejected before JSON decode and before dispatch.
- Nesting above depth 64, collections above 256 items, and strings above 65,536 bytes were rejected.
- Raw and escaped ANSI or OSC controls were rejected.
- Unknown request and runner-frame fields were rejected.
- A new mutating command returned accepted, a replay returned duplicate with the stored envelope, and validation failure returned rejected.
- Runner control sequence state advanced only after verified frames.
- API frame accumulation handled packet-line fragmentation without dispatching a partial frame.
- Captures retained a bounded head, an explicit marker, and a bounded tail.
- Credential-shaped values and sensitive Codex paths were redacted before capture and human rendering.
- Usage rows retained only versioned identity, sequence, logical, outcome, and bounded token counters.
- Capture and usage filesystem faults return typed storage errors; the affected runner capture is quarantined through the workspace transition while durable Attempt state is preserved.

Low-disk behavior was not simulated by filling a host filesystem.

The storage-fault path is intentionally limited to a disposable capture and its Attempt workspace, and the doctor diagnostic reports the typed condition without deleting durable state.

Full prompt, transcript, and raw secret-bearing event retention were not added.

## Exact-head bounded secret redaction follow-up

The exact-head security review found that compound environment names, private-key fields, and PEM material were not covered by the existing bounded redaction families.

Tests-first RED proof retained synthetic `AWS_SECRET_ACCESS_KEY`, `PRIVATE_KEY`, PEM body, and structured `private_key` values in the redaction output.

Commit `c71bee7a6706b7279beafba0a951795124ad7ed4` adds fixed compound assignment patterns, private-key key fragments, and a line-bounded PEM redactor without broadening the regex into an unbounded key matcher.

Tests-first GREEN proof passed the new text and structured-value cases with the existing ContextPack and event redaction regressions; the combined hardening slice passed 11 tests.

The redactor removes the synthetic values while preserving non-sensitive content and remains bounded for oversized non-secret context.

## Exact-head structured redaction follow-up

The exact-head security review found that quoted JSON credential keys such as `access_token` and the `CS_CAPABILITY` environment assignment could retain their values in redacted text.

Commit `522a4675bd75ccc97fdc0d596b4030a2db05077d` extends the assignment redactor to quoted structured keys, token-like key names, and `CS_CAPABILITY` while preserving the surrounding key and separator.

Tests-first RED proof:

    docker run --rm -v "$PWD":/workspace -w /workspace/daemon elixir:1.20-otp-29 sh -lc 'apt-get update -qq && apt-get install -y -qq golang-go >/dev/null && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && MIX_ENV=test mix test test/consigliere/termination_test.exs test/consigliere/harness/redaction_test.exs --no-color'

The new redaction test retained `synthetic-access` from a quoted `access_token` value under the prior implementation.

Tests-first GREEN proof:

    docker run --rm -v "$PWD":/workspace -w /workspace/daemon elixir:1.20-otp-29 sh -lc 'apt-get update -qq && apt-get install -y -qq golang-go >/dev/null && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix test test/consigliere/termination_test.exs test/consigliere/harness/redaction_test.exs --no-color'

Result: 2 passed.

The test covered quoted access and refresh tokens, a quoted secret, and `CS_CAPABILITY`, and asserted that each synthetic value was absent from the redacted output.

The first exact-head full daemon gate then exposed a performance regression in that broad token-like-key expression: the existing 70,000-byte oversized context test timed out while redaction scanned a non-secret string.

Commit `7e0ba5c9d68da26cb450dd9f65c623b5f2a54dda` narrows the structured-key pass to fixed credential key families and keeps the existing bare-key pass, removing the unbounded backtracking path.

GREEN regression proof:

    docker run --rm -v "$PWD":/workspace -w /workspace/daemon elixir:1.20-otp-29 sh -lc 'apt-get update -qq && apt-get install -y -qq golang-go >/dev/null && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix test test/consigliere/harness/context_pack_test.exs test/consigliere/harness/redaction_test.exs --no-color'

Result: 5 passed, including both oversized context tests and the structured redaction test.

## Final runtime audit follow-up

The RED characterization for camel-case keys showed that `apiKey` and `privateKey` values survived the structured redaction pass.

Commit `a3951ec73989f236a075973c373c9c57b2672af9` normalizes separator-free key forms and adds the regression test.

GREEN proof passed the redaction test with both camel-case values replaced by `[REDACTED]`.

The final Linux daemon gate then passed `473 tests` in each of three seed-0 runs, including oversized ContextPack, structured event, fragmented output, and native stream-boundary coverage.

## Watcher follow-up: verifier output bound

At source head `c727e94ae2bac1be0d3d33fc0005258e5fd850cd`, the verifier now checks the accumulated and received byte sizes before concatenating command output.

The RED regression ran one `head -c 200000 /dev/zero` output stream under a bounded process heap and the pre-fix process was killed before returning a bounded result.

The GREEN regression returned `output_too_large` with exactly `65,536` output bytes, and the complete daemon gate passed `499` tests.

The exact RED/GREEN command and bounded output are recorded in `watcher-followup-c727e94.md`.

## Structured payload redaction follow-up

The exact-head review then found that `Redaction.value/1` sanitized nested strings but did not redact values selected by sensitive map keys before harness-event persistence.

Commit `4a22c19313a53faa3fe019f396f58d3cfdbf9a5d` redacts sensitive map-key families before recursion and adds a synthetic event-to-database regression covering `access_token` and `CS_CAPABILITY` values in both the harness-event and domain-event rows.

Tests-first RED proof:

    docker run --rm -v "$PWD":/workspace -w /workspace/daemon elixir:1.20-otp-29 sh -lc 'apt-get update -qq && apt-get install -y -qq golang-go >/dev/null && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && MIX_ENV=test mix test test/consigliere/harness/events_test.exs --no-color'

The new persistence assertion observed `synthetic-event-access` in the stored `access_token` field under the prior implementation.

Tests-first GREEN proof:

    docker run --rm -v "$PWD":/workspace -w /workspace/runner/cs-runner elixir:1.20-otp-29 sh -lc 'apt-get update -qq && apt-get install -y -qq golang-go >/dev/null && go build -o /workspace/daemon/priv/cs-runner . && cd /workspace/daemon && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix test test/consigliere/harness/events_test.exs test/consigliere/pause_test.exs --no-color'

Result: 16 passed.

The retained rows contain `[REDACTED]` for sensitive values and preserve non-sensitive values unchanged.

## CI portability regression

The first final CI run reproduced `CaptureTest` returning `capture_unavailable` when its disposable file lived directly under the shared system temporary directory.

The bounded capture writer was attempting to chmod that existing system directory to `0700`, which correctly fails for a directory owned by another user.

The RED reproduction was the existing head-and-tail capture test in the native macOS suite and the Elixir daemon job of CI run `33294822927`.

The GREEN fix leaves the existing parent directory ownership unchanged and still creates the captured file with mode `0600`.

Command:

    MIX_ENV=test mix test test/consigliere/harness/capture_test.exs --seed 0

Result: 2 passed.

The follow-up implementation commit is `73dfccbb26440fac2ccf9f103f76e4c50762adcc`.

Remote CI run `33295009901` then passed the full Elixir daemon job with 450 tests, including the capture regression, and all four companion jobs.

## Exact-head authenticated stderr and provider-key redaction follow-up

The exact-head review found that provider-prefixed API-key assignments were not covered by the bounded redactor and that authenticated `stderr_chunk` runner frames were ignored by the daemon.

Tests-first RED proof retained synthetic `OPENAI_API_KEY` and `ANTHROPIC_API_KEY` values in redacted text and observed that a harness stderr frame produced no Attempt log.

Commit `e0e3fb3b7f8f8ff5b180f404ff11a5a8efdfe8f6` adds both provider key families to the fixed assignment redaction patterns.

Commit `a2636f70b104988f5c676c2012543a0299064be3` appends authenticated stderr chunks to the bounded Attempt log and advances the heartbeat.

Tests-first GREEN proof passed the focused redaction, runner-process, and runner frame slice with 6 tests.

The redactor remains fixed-family and bounded, and stderr is accepted only after the existing runner identity, fence, sequence, and MAC checks.

## Exact-head fragmented stdout follow-up

The full Linux suite exposed a timing-sensitive failure where a short-lived harness split one Codex JSONL event across runner stdout chunks and the daemon decoded each chunk independently.

The deterministic RED regression split the authenticated completion event across two writes and the prior implementation timed out without reaching `ready_for_review`.

Commit `f1d1dfa02f39bf88b682855a440d8dc6d5214ebf` adds a bounded stdout line buffer owned by `RunnerProcess`, discards oversized unterminated lines without unbounded growth, and preserves complete-line decoding across runner chunks.

Tests-first GREEN proof passed the split completion and fencing regressions with 6 tests.

The final Linux suite then passed three consecutive seed-0 runs with `468 passed (1 doctest, 467 tests)` each.

## Watcher follow-up native command bound

The exact source head `4e99cf4219998c15b01d23b23349730f27546c61` also closes the adjacent native command boundary identified during review.

The RED regression emitted one 200,000-byte `/dev/zero` chunk under a bounded heap and observed `output_too_large` with an unbounded 131,072-byte flattened result.

The GREEN implementation checks the accumulated byte count plus the received chunk size before combining iodata and returns only the remaining bounded prefix.

The focused command passed `7 tests`, and the serial full daemon gate passed `500 tests (1 doctest, 499 tests)`.
