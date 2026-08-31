# Task 2 evidence: one kernel-owned daemon per CS_HOME

Date: 2026-08-29.

Commit scope: \`feat(v0-01): enforce kernel-owned home locking\`.

The implementation is limited to CS_HOME ownership, owner-only home-tree preparation, release-time migration locking, and typed client diagnostics.

## Identity and custody

The isolated worktree is \`/Users/douglasjarquin/.herdr/worktrees/consigliere/cs-consigliere-local-v0-revival\`.

The branch is \`revival/v0-local-codex\`.

The task started from \`origin/rewrite-in-elixer\` at \`24ffea8fa1f5bc983fb5965efab0a89b6116f05b\`.

PR #101 remained open, draft, unmerged, and unchanged during this task.

## RED proof

The new owner-only mode assertion was added before the production mode fix.

The clean Linux-equivalent lock suite then failed with \`20 tests, 1 failure\` because \`/trusted/projects\` retained a non-owner-only mode under the previous \`prepare_dir!/1\`.

The parent-directory assertion then reproduced the same gap for \`/trusted\` and \`/runtime\`.

The new migration callback test was added before \`Home.Lock.with_lock/2\` existed.

The clean targeted suite then failed at \`undefined function Consigliere.Home.Lock.with_lock/2\`, which was the intended missing ownership boundary.

The new Go lock permission test failed before the fix with \`got stale, expected permission\`.

The new Go client and service diagnostic tests failed before the fix because doctor omitted the owner field and \`csd status\` reported \`owner=absent\` for malformed metadata.

## Implementation

\`Consigliere.Home.prepare_root!/1\` now creates and restricts only the CS_HOME root before the kernel lock is acquired.

\`Consigliere.Home.prepare_dir!/1\` now restricts every owned home tree and both trusted and runtime parent directories to mode \`0700\`.

\`Consigliere.Home.Lock.with_lock/2\` acquires the native fcntl lock for release-time external work, reuses the same-VM owner, maps contention to \`:already_running\`, and releases the descriptor in an \`after\` clause.

\`Consigliere.Home.Lock.init/1\` now writes owner metadata, credentials, and sockets only after the native lock is held.

\`Consigliere.Release.migrate/0\` and \`rollback/1\` now perform Ecto work under the home lock without putting the external lock inside a database transaction.

The Go client now distinguishes permission failure from an unowned or stale lock.

The Go client doctor and \`csd status\` now report absent, verified, stale, malformed, and permission owner diagnostics without treating advisory metadata as authority.

## GREEN proof

The clean targeted Elixir command was:

\`MIX_ENV=test mix format --check-formatted && MIX_ENV=test mix test test/consigliere/home/lock_test.exs test/consigliere/home/lock_os_test.exs test/consigliere/home_diagnostics_test.exs test/consigliere/release_test.exs\`.

It passed with \`23 tests, 0 failures\`.

The targeted Go command was:

\`go test ./client ./service -run 'Test(DoctorReportsMalformedOwnerMetadata|StatusReportsMalformedOwnerMetadata|ProbeLockReportsPermissionFailure)$' -count=1\`.

It passed in both packages.

The full CLI gate was:

\`test -z "$(gofmt -l .)" && go vet ./... && go test ./... && go test -race -shuffle=on -count=1 ./... && go build ./cmd/cs ./cmd/csd\`.

It passed with the normal command and race suites, and both binaries built successfully.

\`git diff --check\` passed before commit preparation.

## Packaged process manual QA

The exact package driver command was \`sh .tmp-task2-package-driver.sh\`.

The driver archived the committed baseline, overlaid only the current task-2 files, built \`scripts/package.sh /workspace/prefix\` in a disposable \`elixir:1.20-otp-29\` Linux container with build-only Go and compiler dependencies, and ran the installed binaries as an unprivileged \`qa\` user.

The installed environment used \`env -i\`, a bounded PATH containing only the package and system directories, \`CS_RELEASE\` pointing at the packaged OTP release, and fresh CS_HOME directories.

The two-home and concurrent-start output was:

\`concurrent_success_count=20\`.

\`status_a=home=/tmp/task2-qa/home-a priv=live api=live boss=live lock=held holder=2375 owner=verified\`.

\`status_b=home=/tmp/task2-qa/home-b priv=live api=live boss=live lock=held holder=3851 owner=verified\`.

The driver started both homes and asserted all twenty same-home start commands returned the normal success output.

A regular stale \`boss.sock\` file was placed in home A before startup.

The live boss probe after startup proves the new owner replaced that stale path only after acquiring the kernel lock.

A separate packaged external fcntl-holder probe held a fresh home lock through a FIFO-backed stdin.

The attempted packaged migration returned \`held_migrate_rc=1\` with \`CS_HOME already owned by another daemon\`.

The held-lock assertion also verified that \`consigliere.db\`, \`credentials/boss\`, and \`owner.json\` were not created before ownership.

The home mode was \`0700\` and the lock mode was \`0600\` in that held-lock fixture.

After the exact external probe and its FIFO writer were terminated, packaged migration returned success and created the database.

The driver ended with \`released_migrate=pass\` and \`task2_manual_qa=pass\`.

The container used \`--rm\`, and the host archive/package directory was moved to the macOS trash by the driver trap.

The task-2 package proof does not claim \`csd stop\` or restart lifecycle correctness.

A prior packaged stop attempt exposed the known owner-PID lifecycle gap later assigned to task #134, where stop reported an owner PID that was already dead while live sockets remained.

## Adversarial coverage

Malformed owner JSON and lock permission denial were covered by the client and service tests and by the installed-only diagnostic probe.

That diagnostic probe reported \`owner=malformed\` with the bounded reason \`owner metadata is not valid JSON\`, and reported \`lock=permission\` for an unreadable lock.

External lock contention, no-mutation-before-ownership, FIFO-held hung input, and release-after-probe-kill were covered by the packaged process driver.

Dirty source state was isolated from the package build by using a clean archive plus explicit task-2 overlays.

Misleading socket and owner output was cross-checked with the kernel lock probe, both live socket probes, owner identity diagnostics, and the two distinct home paths.

Prompt injection, cancel or resume, model execution, authorization, dirty Git worktrees, exact-SHA progression, and repeated daemon interruption are not task-2 surfaces and remain unclaimed for their later ordered tasks.

The observed stop/PID issue is recorded as a later-task boundary rather than hidden or broadened into this commit.

## Cleanup receipt

The disposable Docker container was removed by Docker.

The temporary archive and package prefix were moved to the host trash.

The FIFO lock probe, its writer, fresh homes, and package daemons were contained within the removed container.

No shared daemon was stopped, restarted, or updated.

## Current Away shared-resource correction for d63f239

The current runtime source head is `d63f2390944a534f4746c64ef60e43332fd546c3`.

The Away marker and cursor boundary now uses the expanded `CS_HOME` in the shared `:global.trans({{Consigliere.Away, Path.expand(home)}, self()}, fun)` resource.

The concurrent mark regression holds that exact resource in a separate task and proves two real mark calls cannot complete until release, then verifies marker and cursor agreement.

The focused and full daemon results are recorded in `away-return-d63f239.md` and `daemon-gate-d63f239.md`.
