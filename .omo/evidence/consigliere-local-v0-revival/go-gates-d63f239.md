# Exact-head Go gate receipt

Runtime source head: `d63f2390944a534f4746c64ef60e43332fd546c3`.

The unchanged `cli` module passed `gofmt`, `go vet ./...`, ordinary tests, `go test -race -shuffle=on -count=1 ./...`, and `go build ./cmd/cs ./cmd/csd`.

The unchanged `runner/cs-runner` module passed `gofmt`, `go vet ./...`, ordinary tests, `go test -race -shuffle=on -count=1 ./...`, and `go build ./...`.

Both module command groups exited `0`.
