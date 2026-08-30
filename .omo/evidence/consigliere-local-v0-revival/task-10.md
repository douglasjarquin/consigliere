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
