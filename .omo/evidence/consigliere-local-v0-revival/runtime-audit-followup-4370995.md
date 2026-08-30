# Runtime audit: post-review candidate

Reviewed exact candidate head: `43709956c54ab485f9ae077c293f65d269acf27e`.

Runtime source parent: `4e99cf4219998c15b01d23b23349730f27546c61`.

## Runtime hypotheses and observations

1. The prose-test remediation might alter the machine-consumed completion contract.
   `git show 43709956c54ab485f9ae077c293f65d269acf27e:daemon/test/consigliere/harness/context_pack_test.exs` retains the structured authority, reporter, capability, and `completion.require_checkpoint` assertions while removing only the two human-readable wording assertions.
   The focused ContextPack test command passed `5 tests` with exit `0`.

2. The package or production runtime might still differ from the reviewed source after the test-only remediation.
   `git diff --name-status 4e99cf4219998c15b01d23b23349730f27546c61 43709956c54ab485f9ae077c293f65d269acf27e -- daemon/lib cli runner scripts` returned no output.
   The exact-target remote Release smoke job passed in CI run `33328088177`.

3. The watcher fixes might regress under the full daemon surface or the installed user path.
   The serial daemon gate passed `500 passed (1 doctest, 499 tests)` with exit `0`.
   The independent exact-target package QA lane rebuilt a native arm64 package, ran the package-only lifecycle, confirmed the recorded real Codex transition to `ready_for_review`, confirmed default `cs attempt logs` exit `0` with event-only summaries, and verified zero final sockets, PID files, owner files, notifications, and package processes.

## Exact-head custody

Command:

    git rev-parse HEAD
    git branch --show-current
    git diff --check 4e99cf4219998c15b01d23b23349730f27546c61 43709956c54ab485f9ae077c293f65d269acf27e
    git ls-remote origin refs/heads/revival/v0-local-codex refs/pull/141/head

Observed:

    head=43709956c54ab485f9ae077c293f65d269acf27e
    branch=revival/v0-local-codex
    diff_check_exit=0
    refs=43709956c54ab485f9ae077c293f65d269acf27e

The candidate delta from the runtime parent is two deleted prose-only test assertions and no production, package, CLI, or runner input change.

## Boundary results

- The verifier and native runtime command both cap a received chunk before normal accumulation or flattening.
- The ContextPack machine contract requires one terminal completion without a preceding checkpoint, and its test now checks structured fields rather than prompt wording.
- The default advisory `attempt.logs` operation remains authorized, bounded, event-only, and redacted; captured free-form log text, prompts, secrets, and private paths remain unavailable.
- The packaged real Codex completion, exact-SHA import, bounded verification, lifecycle restart, repeated stop, and cleanup receipts remain bound to runtime parent `4e99cf4219998c15b01d23b23349730f27546c61`, which is byte-identical to the candidate's production inputs.

## Independent final review lanes

- Plan compliance: PASS at `43709956c54ab485f9ae077c293f65d269acf27e`.
- Hands-on package QA: PASS at `43709956c54ab485f9ae077c293f65d269acf27e`.
- Code quality: PASS, with non-blocking maintainability watch items for pre-existing oversized modules and timing-sensitive polling tests.
- Security and boundary review: PASS at `43709956c54ab485f9ae077c293f65d269acf27e`.
- Scope fidelity: the exact diff adds no excluded integration or canary behavior; inherited non-V0 modules remain unchanged from the historical base and are unreachable from the packaged V0 path.

## Cleanup and ruled-out classes

The package QA lane used only fresh task-owned temporary resources and moved them to macOS Trash, leaving zero package processes, matching sockets, PID files, owner files, notifications, or QA tmux sessions.

Malformed input, prompt injection, secret/path leakage, advisory authority escalation, stale capability/fence/generation identity, dirty or unsafe workspace, invalid or non-descendant SHA, duplicate terminal reports, cancellation/checkpoint, hung or oversized command output, interruption/restart, duplicate canary work, Made execution, delivery, push, PR creation, and merge were ruled out by the existing exact runtime receipts, focused tests, full gate, or explicit scope boundary.

No credentials, raw prompts, transcripts, or unredacted logs are retained in this record.

## Verdict

PASS for exact candidate head `43709956c54ab485f9ae077c293f65d269acf27e`.
