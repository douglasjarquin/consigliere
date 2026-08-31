# Historical exact-head cancellation ordering receipt

Source head: `cf56963a7206e5c5a260442c08eaa7bdcd65ec7a`.

The RED regression reproduced `runner_cancel` delivery finalizing a still-registered runner as lost before verified process-group death.

The GREEN fix makes delivery request runner cancellation only; the reconciler and RunnerProcess exit path retain responsibility for terminal outcome and workspace disposition after verified death.

The focused command `PATH=/opt/homebrew/opt/erlang/bin:$PATH MIX_ENV=test mix test test/consigliere/termination_test.exs test/consigliere/dispatch_test.exs --no-color --seed 0` passed `4 tests` with exit `0` after format and warnings-as-errors compilation.

The test-only runner stub proved that a live registered Attempt remains `terminating` immediately after delivery.

Applicable adversarial classes were live-runner cancellation, unknown death, workspace custody, repeated interruption, and stale terminalization.

Malformed protocol input, prompt injection, dirty worktrees, hung external commands, and exact Git SHA import are outside this cancellation ordering path and remain covered by the owning task evidence.
