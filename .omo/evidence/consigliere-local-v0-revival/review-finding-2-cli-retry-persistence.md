# Review finding 2: generated mutating request persistence

The retry implementation is package-local to `cli/client` and uses the existing `Home.Dir` path field and `CanonicalRequestHash` helper from that package.

## RED

Before the implementation, the subprocess restart regression failed because a generated idempotency key changed between processes.

```text
idempotency key changed across process restart: first=cs-1e9c9f13b6a5c118b59786290a21889 replay=cs-65904e467428de441ca2ff6e5e2009ad
```

## GREEN

```text
$ go test ./client -count=1 -run '^TestGeneratedMutatingRequestSurvivesProcessRestart$' -v
--- PASS: TestGeneratedMutatingRequestSurvivesProcessRestart
PASS
ok github.com/douglasjarquin/consigliere/cli/client
```

The package-wide Go test also passed with `go test ./... -count=1`.
The test exercises a dropped first response, a new helper process, reuse of the persisted idempotency key and canonical hash, and removal of the request receipt after the successful replay.

The malformed-input and prompt-injection classes are covered by the existing request validation and protocol tests; this finding's new boundary is transport response loss across process restart.
