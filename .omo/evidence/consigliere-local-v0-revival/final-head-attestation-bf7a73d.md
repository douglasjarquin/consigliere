# Historical implementation-head attestation

Historical implementation head: `bf7a73dd005fe6c1746a1c73f1929411cd7392c1`.

The exact-head daemon suite returned `502 passed (1 doctest, 501 tests)`.

The CLI and runner Go inputs were unchanged by this source commit and their fresh prior exact-head gates returned success.

The package command was `scripts/package.sh .tmp/package-final-bf7a73d` and returned `RC=0`.

The rebuilt package artifacts were native arm64 Mach-O files with these SHA-256 values:

```text
cs 9343bd161c27d0e993c53d6b78fcf9a4b9528e39743f2c6e1c293f36453eadb7
csd b1ea9eb5319f08cadb39baa525bd251a889401b856d4e04ee631ee1d5c85e8d6
cs-runner d31abc27b8123d8da44e4fdce956d4b0e226819327790876aa97dc60ef23322e
cs-attempt 77eab4851d7dfe10e6d8fe736f83eab7a9fff5fb6be4815777670b4e9f7242bb
erlexec 0d58107509b1c59399cf3c9bdbf495b2f05f1fb4a5492c19cb886c65fb4c96d6
```

The fresh package-only lifecycle used `env -i` and fresh `/tmp` homes, exercised `cs projects` and `cs review` before and after restart, verified owner identity, converged repeated stop, and ended with zero sockets, PID files, owner files, and package processes.

The package prefix and fresh homes were moved to macOS Trash after the assertions passed.

The prior exact-head real-Codex and operator-controlled canary evidence was not duplicated; this source change only adds deterministic ordering to already bounded reader records.
