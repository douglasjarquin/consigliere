# F2 code-quality review

## Verdict

Target reviewed: `71593738cf6aae723c9208743405fa12a9dc7a03` on `revival/v0-local-codex`.
Base: `24ffea8fa1f5bc983fb5965efab0a89b6116f05b`.

`codeQualityStatus: WATCH`

`recommendation: APPROVE`

`blockers: none`

I found no unresolved CRITICAL or HIGH correctness, authority, persistence, identity, or lifecycle defect in the Git-object diff.
The branch is unusually large for a revival (189 tracked files and 19,591 inserted lines), so this is an approval with concrete maintainability and test-determinism follow-up rather than a clear bill of health.

## Scope and evidence discipline

The requested SHA was HEAD and the requested branch was checked out when reviewed.
`git diff --check` against the supplied base was clean.
The worktree has unrelated modified and untracked runtime/evidence files, so conclusions are based on the two Git objects and source inspection, not those worktree artifacts.

I read the supplied plan, including its F2 criteria, and inspected the full base-to-target file list plus the late runtime hardening diffs.
Existing receipts at `.omo/evidence/consigliere-local-v0-revival/*7159373*` claim complete daemon, package, lifecycle, and Go gates; they were treated as untrusted claims, not as proof.
The reviewer independently ran the CLI format/vet/race/build gate successfully.
The native daemon command could not be run in this shell because the local Elixir launcher failed with `exec: erl: not found`.
The runner race gate was started, its test processes later exited with no leftover `cs-runner` process, but this tool session did not return a final exit receipt; do not count that as independent green evidence.

## Architecture and boundary review

The durable/external boundary is generally soundly modeled.
Result reporting, runner-death confirmation, commit verification, import, and Project verification are staged in `daemon/lib/consigliere/progression.ex` rather than held inside one SQLite transaction.
Attempt result identity includes Mission, Project, Workspace, lease generation, fence, base/checkpoint SHA, and terminal sequence in `daemon/lib/consigliere/attempt_results.ex`.
The advisory principal is constrained to read operations plus Mission drafts; `mission.create` persists only the `draft` phase, while submit and work authorization require Boss authority (`daemon/lib/consigliere/missions/transitions.ex:23-25, 26-42, 77-84`; `daemon/lib/consigliere/api/protocol.ex:28-30, 97-105`).
The runner control channel validates a bound invocation identity and authenticated sequencing before accepting frames (`runner/cs-runner/control.go:72-125`).
The detached runner broker waits for its session child and propagates child failure instead of reporting a completed broker while the real runner is still live (`runner/cs-runner/main.go:62-77`).

## Findings

### CRITICAL

None.

### HIGH

None.

### MEDIUM

- `daemon/lib/consigliere/api/protocol.ex:1`, `cli/client/run.go:1`, `daemon/lib/consigliere/runner_process.ex:1`, `daemon/lib/consigliere/runner_launcher.ex:1`, `daemon/lib/consigliere/attempts/transitions.ex:1`, `daemon/lib/consigliere/missions/transitions.ex:1`, `runner/cs-runner/control.go:1`, and `runner/cs-runner/main.go:1` are 345 to 898 pure lines each.
  They combine multiple independent responsibilities (protocol validation/dispatch/authorization, CLI parsing/workflow confirmation, runner lifecycle/frame processing, and state transitions).
  This violates the consulted `remove-ai-slops` and `programming` size and separation perspective, makes security-sensitive review harder, and makes future changes more regression-prone.
  No immediate semantic failure was demonstrated, so this is MEDIUM rather than HIGH.

- `runner/cs-runner/detached_test.go:14-52` uses wall-clock polling and `syscall.Kill(pid, 0)` to prove termination, while its helper intentionally sleeps for 60 seconds (`runner/cs-runner/testmain_test.go:62-72`).
  In the independent attempt, the race gate remained active for about a minute before all related processes disappeared.
  A zombie can still answer `Kill(pid, 0)` successfully until reaped, so this test can wait until the helper's natural timeout and produces an unnecessarily slow, scheduler-sensitive signal rather than a deterministic lifecycle assertion.
  This is a relevant test-quality defect, not evidence that production termination is wrong.

- `daemon/test/consigliere/api_socket_test.exs:21-25` and `daemon/test/consigliere/chaos_security_test.exs:222-227` mirror the global `CS_HOME` test constant instead of querying `Home.dir/0`.
  The change is neither deletion-only nor tautological, but it couples two socket tests to the current test config and will fail misleadingly if the configured test home changes.
  Use the configured home at the consumer seam in a follow-up.

### LOW

- `runner/cs-runner/main.go:13-24` contains long explanatory comments about a polling trade-off without an enforced ceiling or measured test assertion.
  The comments explain intent, so they are not slop by themselves; the low-risk issue is that the documented cost/escape-window trade-off is not encoded in a named policy or test.

## Skill-perspective check

This check ran.
I consulted `omo:programming` and its Go guidance before judging tests and maintainability, and ran the `omo:remove-ai-slops` review criteria against production and tests.

No deletion-only test, prompt/prose assertion, test that merely proves a requested removal, or output-derived tautological assertion was found in the reviewed late changes.
The diff does violate both skill perspectives on oversized multi-responsibility modules and timer/polling-heavy lifecycle tests, as recorded above.
I did not find unnecessary production parsing, normalization, or extraction that is unrelated to the V0 trust, protocol, identity, and reconciliation goals.

## Residual risks

The complete daemon and runner gates still need a reproducible, independently captured final-head receipt from an environment with Erlang available; existing receipts alone are insufficient for that claim.
The current native test configuration serializes the daemon suite and shares a fixed `/tmp/consigliere-daemon-test-home`, so parallel test execution is not supported and host contamination remains a risk outside the prescribed one-case test mode.
The large protocol, lifecycle, and transition modules concentrate future change risk at the exact boundaries that protect durable state and authority.
