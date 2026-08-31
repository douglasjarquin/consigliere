# Exact-head termination reconciliation receipt

Source head: `f064f4f79d9865c27c083e2dbf47e039cbe09c3f`.

Cancellation delivery requests runner termination without finalizing the Attempt before verified death.

The requested cause is persisted on the terminating Attempt, and an unverified exit from `terminating` now follows the existing `mark_lost` path, quarantining the workspace and holding the scheduler slot for reconciliation.

The focused termination, dispatch, recovery, and classify-exit proof passed `18 tests`.

Applicable adversarial classes were live-runner cancellation, unverified runner death, unknown death, stale cause state, workspace custody, repeated interruption, and terminal classification.
