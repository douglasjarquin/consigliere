# Historical implementation-head attestation

Historical implementation head: `df939ab3e06c1c5bad15ae4156b27bfeae805b16`.

The exact-head daemon suite returned `502 passed (1 doctest, 501 tests)`.

The CLI and runner Go inputs were unchanged by this source commit and their fresh prior exact-head gates returned success.

The package command was `scripts/package.sh .tmp/package-final-df939ab` and returned `RC=0`.

The rebuilt package artifacts were native arm64 Mach-O files with these SHA-256 values:

```text
cs 15b89a90cda0cb2988c52c078bc6e633d56d877a5772021ed152112bb4d25b6e
csd d81d9e9aee7464d1ff879db309af778f97eea2bc1db424547a8983c7af6b329f
cs-runner cba28dbd4797de460ba627daf9c82a5adddc8cac66d249f65da789938ad0bd53
cs-attempt 4904b2fa3da214db9c5b83f0e38fd7faed9ad8e0a462679c1b4b4992505e0a40
erlexec 0d58107509b1c59399cf3c9bdbf495b2f05f1fb4a5492c19cb886c65fb4c96d6
```

The fresh package-only lifecycle used `env -i` and fresh `/tmp` homes, exercised `cs projects` and `cs review` before and after restart, verified owner identity, converged repeated stop, and ended with zero sockets, PID files, owner files, and package processes.

The package prefix and fresh homes were moved to macOS Trash after the assertions passed.

The prior exact-head real-Codex and operator-controlled canary evidence was not duplicated; this source change only bounds the remaining reader queries after the deterministic ordering fix.
