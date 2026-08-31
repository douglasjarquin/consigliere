# Historical exact-head cancellation cause and ordering receipt for ec47784

Source head: `ec47784a801ee8168fae7b249bf3b8342951ae17`.

Cancellation delivery requests runner termination without finalizing the Attempt before verified death.

The requested cause is persisted on the terminating Attempt, so `failed`, `paused`, and `superseded` outcomes remain available to RunnerProcess and reconciler classification.

The focused termination and dispatch proof passed `4 tests`, including live-runner deferral and durable failure-cause coverage.

Applicable adversarial classes were live-runner cancellation, unknown death, stale cause state, workspace custody, repeated interruption, and terminal classification.
