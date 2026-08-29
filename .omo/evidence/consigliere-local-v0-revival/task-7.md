# Task 7 evidence: authenticated and isolated runner control channels

Branch: `revival/v0-local-codex`.

Base: `24ffea8fa1f5bc983fb5965efab0a89b6116f05b`.

Commit: `feat(v0-06): authenticate runner control channels`.

The daemon now creates a unique invocation identity and a cryptographically random 32-byte channel secret for every launch.

The secret crosses the daemon-to-runner boundary only as one JSON bootstrap line on the inherited private stdin pipe.

The runner closes stdin after the daemon completes the manifest-verified handshake, and the daemon session retains only an opaque per-process ETS table reference rather than the secret bytes.

The control socket is created under an owner-only invocation directory with a 0600 socket and is never replaced through a symlink or an existing path.

The daemon and runner mutually authenticate canonical HMAC-SHA-256 challenge, hello, and acknowledgement messages.

Every authenticated frame carries the exact protocol, invocation, Attempt, Mission, workspace, workspace generation, fencing generation, sequence, and fencing-token identity.

The runner accepts only signed cancel, ping, and checkpoint control frames.

Invalid, replayed, mismatched, oversized, and out-of-sequence frames are rejected without advancing sequence state or invoking application callbacks.

Only an authenticated channel EOF reaches the runner termination path.

The manifest digest, runner and harness executable hashes, PID, process group, socket path, and durable identity are checked before `runner_started` is accepted.

Focused daemon process integration:

```text
docker run --rm -v "$PWD:/workspace" -w /workspace/daemon elixir:1.20-otp-29 sh -lc 'apt-get update -qq >/dev/null && apt-get install -y -qq golang-go >/dev/null && export PATH=/usr/local/bin:/usr/bin:/bin && mix local.hex --force >/dev/null && mix deps.get >/dev/null && MIX_ENV=test mix test --no-color test/consigliere/runner_process_test.exs test/consigliere/runner_process_env_test.exs test/consigliere/runner_process_fencing_test.exs'
Result: 4 passed
```

The full Linux daemon gate was rerun after the secret-storage and lifecycle fixes.

```text
docker run --rm -v "$PWD:/workspace" -w /workspace/daemon elixir:1.20-otp-29 sh -lc 'apt-get update -qq >/dev/null && apt-get install -y -qq golang-go >/dev/null && mix local.hex --force >/dev/null && mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test --no-color'
Result: 405 passed (1 doctest, 404 tests)
```

The runner normal, race, vet, and build gates passed after `gofmt`.

```text
cd runner/cs-runner && go test ./... && go test -race -shuffle=on -count=1 ./... && go vet ./... && go build ./...
Result: all commands passed
```

A temporary real-process driver was created at `daemon/task7_manual.exs`, run in a fresh migrated Linux container, and moved to macOS Trash after the run.

```text
CS_HOME=/tmp/task7-manual-home MIX_ENV=test mix run task7_manual.exs
TASK7 attacker_first_rejected=true
TASK7 parent_mode=0700 socket_mode=0600
TASK7 identity_unique=true
TASK7 invalid_frame_no_side_effect=true
TASK7 cancel_verified=true
TASK7 authenticated_eof_verified=true
TASK7 secret_scan=true
TASK7 runner_argv_env_secret_absent=true
TASK7 result=pass
```

The driver launched two real `cs-runner` processes, connected an attacker before the daemon handshake, sent an invalid frame before a valid signed cancel, checked the two invocation and socket identities, checked owner-only modes, observed authenticated cancellation and authenticated daemon-loss EOF, and scanned bounded process, session, and manifest representations for secret-shaped fields.

The runner crash log was also inspected during the exit-status test.

The durable GenServer state contained only `secret_ref: #Reference<...>` and no channel secret bytes.

Adversarial coverage included malformed bootstrap and frame input, attacker-first connection, forged identity, replayed handshake/frame sequence, oversized handshake, stale fencing and workspace identity, invalid MAC, repeated invalid interruption before a valid cancel, and a real authenticated EOF.

Prompt injection was ruled out for this boundary because the control protocol carries no model prompt, transcript, or free-form instruction that reaches an authority handler.

Resume was not claimed here because V0 has no native or control-channel resume operation; fresh continuation is covered by the ordered dispatch and Codex tasks.

Dirty Git worktrees were ruled out for this task because the runner channel performs no Git operation and receives no source-repository authority.

Hung handshake and termination paths are bounded by accept, read, and process-group cleanup deadlines.

Misleading runner prose cannot establish identity because the daemon requires the exact digest, manifest fields, executable hash, PID, process group, and HMAC before accepting frames.

The coordinator reattachment test's fixed sleep was replaced with a bounded heartbeat wait after reproducing a timing failure, and the full suite passed afterward.

No secret, credential, model context, transcript, GitHub action, PR action, merge action, Made action, or legacy supervisor dependency was added to the channel.

The temporary manual driver and generated runner binary were both moved to Trash, and `git diff --check` was clean.
