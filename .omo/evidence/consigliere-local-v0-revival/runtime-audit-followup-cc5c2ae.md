# Runtime audit: default Attempt log boundary

Reviewed runtime source head: `cc5c2ae368007ec30fba81d74d5a30808176a9d8`.

The shared authorized `attempt.logs` route applies the existing bounded event-only projection before returning a response.

The regression rejects raw captured text, bearer-shaped secret text, prompt-like text, private paths, and unallowlisted response keys.

The focused API, advisory, and protocol suite passed 21 tests.

The serial daemon gate passed 500 tests.

The runner and CLI race gates passed with exit 0.

The exact-head package and real-Codex terminal run reached `ready_for_review`, returned event-only default Attempt logs, enforced the 65,536-byte command-output bound, changed owner identity after restart, accepted repeated stop, and left no socket or PID residue.

Existing adversarial coverage continues to cover malformed input, prompt injection, cancellation and interruption, stale identity, dirty workspaces, hung commands, duplicate terminal reports, exact-SHA mismatch, and misleading output.

No native Codex resume, raw transcript retention, authority-bearing advisory operation, automatic GitHub delivery, canary duplicate, Promote claim, or Made daemon mutation was introduced.

## Verdict

PASS for runtime source head `cc5c2ae368007ec30fba81d74d5a30808176a9d8`.
