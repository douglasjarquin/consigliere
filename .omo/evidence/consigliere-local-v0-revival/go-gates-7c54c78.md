# Go gates at exact source head

Date: 2026-08-30.

Target source head: `7c54c782552f3ee5a09ddee35735e90cba1b9339` on `revival/v0-local-codex`.

The CLI command was:

```text
cd cli && test -z "$(gofmt -l .)" && go vet ./... && go test ./... && go test -race -shuffle=on -count=1 ./... && go build ./cmd/cs ./cmd/csd
```

The CLI command exited `0`.

The runner command was:

```text
cd runner/cs-runner && test -z "$(gofmt -l .)" && go vet ./... && go test ./... && go test -race -shuffle=on -count=1 ./... && go build ./...
```

The runner command exited `0`.

The runner ordinary suite was cached after the preceding exact-source run, and the race/shuffle suite returned `ok` in `44.178s`.

Both gates passed formatting, vet, ordinary tests, race and shuffle tests, and builds.

The output receipts are bounded and contain no credentials, prompts, transcripts, or raw canary data.

Verdict: PASS.
