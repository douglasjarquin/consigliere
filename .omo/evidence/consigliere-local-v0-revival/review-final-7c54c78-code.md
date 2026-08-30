# Final code-quality review - Consigliere Local V0 revival

## Verdict

Target reviewed: `7c54c782552f3ee5a09ddee35735e90cba1b9339` on `revival/v0-local-codex`.
Base reviewed: `24ffea8fa1f5bc983fb5965efab0a89b6116f05b`.

`codeQualityStatus: WATCH`

`recommendation: APPROVE`

`blockers: none`

The full Git-object diff is clean for whitespace and contains no unresolved CRITICAL or HIGH correctness, authorization, SQLite-authority, identity, lifecycle, or reconciliation defect.
This is a bounded approval with maintainability and test-determinism follow-up, not a claim that the unusually large revival is free of future-change risk.

## Scope and evidence

The target SHA resolves and is the checked-out `HEAD` on the requested branch.
The supplied base is an ancestor of the target.
The object diff contains 200 files changed, with 20,703 insertions and 1,268 deletions.
`git diff --check 24ffea8fa1f5bc983fb5965efab0a89b6116f05b 7c54c782552f3ee5a09ddee35735e90cba1b9339` passed.

The worktree contains pre-existing modified and untracked evidence, build, and scratch artifacts.
They were not treated as source changes or proof of success.
The report is bound only to the two requested Git objects and independently inspected source and test output.

## Independent verification

- CLI: `gofmt` check, `go vet ./...`, `go test -race -shuffle=on -count=1 ./...`, and builds for `cs` and `csd` passed.
- Runner: `gofmt` check, `go vet ./...`, `go test -race -shuffle=on -count=1 ./...`, and `go build ./...` passed in 44.450 seconds.
- Daemon: a fresh Linux container built `cs-runner`, ran daemon formatting and warnings-as-errors compilation, then passed `496 passed (1 doctest, 495 tests)` at this exact SHA.
- Existing package and lifecycle receipts were inspected only as corroborating, redacted artifacts, not substituted for the checks above.

## Review coverage

I audited the full base-to-head diff and focused on authority ownership, SQLite transaction boundaries, capabilities and protocol authentication, Git/workspace binding, process and executable identity, runner reconciliation, termination and restart lifecycle, schema/migration consistency, bounded error handling, and test relevance.

The durable writer and outbox patterns keep external Git, runner, process, and verification work out of SQLite transactions.
The control protocol binds invocation, mission, workspace generation, fencing generation, sequence, and MAC before accepting frames.
The current identity path adds executable hashing, process-start fingerprints, membership checks, bounded native observers, and fail-closed inventory classifications before a process group is signalable.
No automatic canary decision, Made interaction, merge, PR mutation, or daemon action was performed in this review.

## Findings

### CRITICAL

None.

### HIGH

None.

### MEDIUM

- `daemon/lib/consigliere/api/protocol.ex:1`, `daemon/lib/consigliere/runner_launcher.ex:1`, `daemon/lib/consigliere/runner_process.ex:1`, `daemon/lib/consigliere/progression.ex:1`, `daemon/lib/consigliere/capabilities.ex:1`, `cli/client/run.go:1`, `runner/cs-runner/control.go:1`, and `runner/cs-runner/main.go:1` remain large multi-responsibility modules, with several exceeding the consulted skills' 250 pure-LOC threshold.
  They combine high-risk concerns such as protocol parsing, authorization, lifecycle management, persistence transitions, and I/O.
  This makes future security and recovery changes harder to review and isolate.
  No present semantic failure was demonstrated, so this is MEDIUM rather than HIGH.

- `daemon/test/consigliere/runner_process_test.exs:34`, `daemon/test/consigliere/runner_launcher_test.exs:211`, `daemon/test/consigliere/reconciler_persist_test.exs:499`, and related lifecycle tests rely on polling with `Process.sleep` or `kill -0`.
  The exact runner race/shuffle gate takes 44.450 seconds, which corroborates that termination coverage carries a meaningful timing cost.
  These tests exercise real outcomes, but polling can be scheduler-sensitive and a zombie can still satisfy `kill -0` until reaped.
  Prefer an explicit process-exit/reap signal for future lifecycle coverage.

### LOW

- `daemon/lib/consigliere/runtime/command.ex:30-31` checks the output limit only after a complete port message has been received and materializes that message in the returned error payload.
  The timeout and nominal bound protect normal observer calls, but a hostile or unexpectedly verbose native observer can still make one inbound message exceed `@max_output` before rejection.
  The only current callers are fixed absolute-path system observers, so this is a bounded hardening opportunity rather than a demonstrated exploit.

## Skill-perspective check

This check ran before judging maintainability and test relevance.
I consulted `omo:programming` and its Go references for concurrency, error handling, data modeling, types, and testing, and applied the full `omo:remove-ai-slops` review criteria to the production and test diff.

The diff violates both skill perspectives on oversized multi-responsibility modules and timer/polling-heavy lifecycle tests, as recorded above.
I found no deletion-only test, test that merely verifies a requested removal, natural-language prompt assertion, output-derived tautology, implementation-constant mirror presented as behavior coverage, untyped Go escape hatch in a domain boundary, or needless production parsing, normalization, or data extraction unrelated to the V0 trust and identity goals.

## Residual risks

- The branch's size concentrates authority and recovery complexity in a small number of oversized modules, increasing regression risk for later edits.
- Lifecycle tests remain slower and less deterministic than necessary because they poll operating-system state.
- Process identity depends on OS observer interfaces such as `/proc`, `ps`, `lsof`, `realpath`, and `shasum`; the implementation fails closed when observation is unavailable, but host-specific coverage should remain part of release verification.
- The reviewed evidence is sufficient for this code-quality verdict, but canary promotion remains an operator-owned decision and is outside this review.

## Final status

`codeQualityStatus: WATCH`

`recommendation: APPROVE`

`reportPath: .omo/evidence/consigliere-local-v0-revival/review-final-7c54c78-code.md`

`blockers: none`
