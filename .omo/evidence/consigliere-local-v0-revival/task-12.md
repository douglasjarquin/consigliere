# Task 12 evidence

## Scope

Task #12 is the plan's issue #134, identity-safe `csd stop` and restart.

The implementation commit is 67ce78e13dfbc0a938d47706455a85cfaf73d4c6.

The implementation binds lifecycle control to canonical `CS_HOME`, complete owner metadata, the kernel lock holder, process start time, executable, process group, and bounded runner inventory.

It requests the privileged authenticated daemon shutdown before bounded observation, refuses ambiguous identities, revalidates immediately before process-group signals, cleans stale sockets only while holding the home lock, and starts a replacement only after verified stop.

LaunchAgent labels and plist paths are derived from the canonical home so two homes cannot unload or overwrite one another's service identity.

## Tests-first record

The initial RED characterization ran the new identity and cleanup cases against the existing lifecycle implementation.

The command failed three tests: incomplete owner metadata was accepted, a wrong-home owner record was treated as stopped, and a stale socket was left behind without an acquired cleanup lock.

The implementation then made those cases green and added regression coverage for process-group and start-time binding, symlink substitution, live orphan runners, cross-home cleanup, and home-specific LaunchAgent identity.

## Automated verification

Command:

    cd cli && test -z "$(gofmt -l .)" && go vet ./... && go test ./... && go test -race -shuffle=on -count=1 ./...

Result: Go formatting, vet, unit, and race suites passed for `cli/client`, `cli/service`, `cs`, and `csd`.

Command:

    docker run --rm -v "$PWD:/repo" -w /repo/daemon elixir:1.20-otp-29 sh -lc 'mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test test/consigliere/api_protocol_test.exs test/consigliere/application_boot_result_test.exs test/consigliere/home_diagnostics_test.exs test/consigliere/process_group_test.exs test/consigliere/kill_everything_test.exs'

Result: 30 passed.

The daemon compile completed with warnings treated as errors.

## Packaged process QA

The exact package entry point was exercised with `scripts/package.sh` in a disposable `elixir:1.20-otp-29` container.

The container used Linux-built Go clients and runner artifacts, and the final package contained Linux `cs`, `csd`, the OTP release, and `cs-runner`.

The installed-only driver mounted only the package prefix and a fresh temporary home, ran as a non-root user, used `PATH=/opt/consigliere/bin:/usr/bin:/bin`, set `CS_RELEASE` to the installed release, and ran from `/tmp`.

The driver invoked the installed `csd migrate`, `csd start`, `cs ping`, `cs doctor`, `csd status`, `csd stop`, a second idempotent `csd stop`, `csd restart`, `cs ping`, and a final `csd stop`.

Bounded observed output included:

    migrated /home/cs-home/consigliere.db
    started home=/home/cs-home
    pong
    lock: /home/cs-home/lock held pid=93
    home=/home/cs-home priv=live api=live boss=live lock=held holder=93 owner=verified
    stopped
    stopped
    restarted
    pong
    stopped
    TASK12_PACKAGE stop=verified restart=verified idempotent_stop=verified

The driver asserted that owner metadata and all three sockets were absent after each successful stop, while the lock path remained present.

The package ran without a source checkout, Mix command, or legacy Bash supervisor on `PATH`.

## Adversarial coverage

- Incomplete, malformed, wrong-home, stale, wrong-executable, wrong-start-time, wrong-process-group, held-lock, permission, foreign-PID, and recycled-PID identity cases refuse control and preserve evidence.
- Stale sockets are removed only after the stop process acquires the target home lock, and symlink lifecycle artifacts are refused without following the substitution.
- A live runner manifest with missing daemon ownership prevents a successful stop and is never signaled by `csd`.
- A live daemon is asked to stop through the authenticated boss socket before bounded process observation and group fallback.
- The exact daemon process group is revalidated immediately before SIGTERM or SIGKILL, and the final process, group, lock, socket, and runner observations are required before success.
- Process-group members and runner manifests are bounded and checked after daemon shutdown, so a lingering or ambiguous runner produces an incomplete result.
- A second home is not cleaned during stop, and distinct homes receive distinct LaunchAgent labels and plist paths.
- Delayed shutdown is bounded by graceful, SIGTERM, and SIGKILL observation windows; a failed observation returns an incomplete error rather than zero.
- Daemon shutdown marks the local Termination gate before stopping, so new API work is refused while reads and the shutdown request remain available.
- Prompt injection, Codex resume, and model-authored lifecycle commands were not applicable to this boundary because `csd` consumes only local owner, lock, socket, and bounded manifest identity.
- Dirty Git workspaces and exact result progression remain outside `csd` lifecycle control and are covered by tasks 4 and 13.
- No cross-home cleanup, bare PID authority, kill-by-name behavior, automatic GitHub action, PR creation, merge, Made operation, telemetry, or transcript retention was added.

The invalid first cross-platform package prefix, final package prefixes, Linux prebuilt binaries, temporary wrapper, generated runner binary, and lifecycle home were moved to the macOS Trash after the successful final package run.

No credentials, raw logs, or transcripts were written to this evidence record.

`git diff --check` passed before the implementation commit.
