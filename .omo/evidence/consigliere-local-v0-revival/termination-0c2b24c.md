# Exact-head termination reconciliation receipt

Source head: `0c2b24c02490c8f6f53b7f6bc1a9fb9add519861`.

Cancellation delivery requests runner termination without finalizing the Attempt before verified death.

The requested cause remains durable, and an unverified exit from `terminating` follows the existing lost, quarantine, and scheduler-slot hold path.

The focused Away, termination, dispatch, recovery, and classify-exit proof passed `25 tests`, including later verified death releasing a slot held by an unverified cancellation.

Applicable adversarial classes were live-runner cancellation, unverified runner death, unknown death, stale cause state, workspace custody, repeated interruption, stale marker replacement, and terminal classification.
