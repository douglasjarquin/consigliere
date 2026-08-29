# Task 5 evidence: packaged Project, Mission, and authorization workflow

Plan item: #131, `Complete the packaged terminal Project, Mission, and authorization workflow`.

Branch: `revival/v0-local-codex`.

Base: `24ffea8fa1f5bc983fb5965efab0a89b6116f05b`.

Commit: `feat(v0-04): complete terminal mission authorization`.

The RED Go tests first failed because `mapCommand` treated `project add`, Mission submit, request-changes, and authorize as read or unknown commands.

The RED workflow test also showed that authorize did not use the boss socket or return a durable Authorization identity.

The Go client now exposes the exact V0 terminal commands for Project add, Mission create, Mission submit, Mission request-changes, and Mission authorize.

Task-5 mutation commands use the authenticated privileged socket and never open SQLite or mutate the trusted mirror in the client.

Human mutation commands fetch the durable Project or Mission preview before confirmation and display Project identity, Mission identity, objective, scope, acceptance criteria, and immutable base SHA when available.

Noninteractive automation requires explicit `--yes` and a stable `--idempotency-key`.

Foreground confirmation accepts only an explicit `y` or `yes` response.

Human Project and Mission projections include stable IDs, phases, configured branch, base ref, base SHA, and Authorization ID where applicable.

The daemon protocol now returns the durable Project base identity and complete Mission contract fields.

Mission request-changes records its bounded reason in the domain event.

Project registration rejects a duplicate canonical source before external mirror work and returns a typed conflict envelope.

The required daemon CLI suite plus added workflow characterization tests passed:

```text
MIX_ENV=test mix test test/consigliere/api_cli_ops_test.exs test/consigliere/api_protocol_test.exs test/consigliere/api_socket_test.exs test/consigliere/cli_test.exs test/consigliere/cli_main_test.exs test/consigliere/projects_test.exs test/consigliere/missions/transitions_test.exs
Result: 50 passed
```

The Go client suite passed after the RED tests were implemented.

```text
go test ./...
Result: client and service tests passed; command packages reported no test files.
```

The real manual QA built `scripts/package.sh` in a disposable Linux container, created a fresh unprivileged operator user, and ran only the installed `cs` and `csd` binaries with a package-only `PATH`.

The driver ran `csd migrate`, `csd start`, Project add, Project read in JSON and human formats, Mission create, Mission read in JSON and human formats, submit, request-changes, resubmit, authorize, and authorize replay.

The first authorization response returned one durable Authorization ID and replay returned the same ID.

The driver exercised invalid repository, duplicate Project, invalid branch, missing Mission field, wrong phase, and removed source checkout cases and observed nonzero exits.

The driver used `strace` on a packaged read command and found no open of the home SQLite database by the Go client.

```text
base_sha_length=40
authorization_replay_same=yes
human_project_read=pass
human_mission_read=pass
invalid_repository_exit=nonzero
duplicate_project_exit=nonzero
invalid_branch_exit=nonzero
missing_field_exit=nonzero
wrong_phase_exit=nonzero
removed_source_exit=nonzero
client_sqlite_trace=clean
task5_manual_qa=pass
```

The package driver and disposable container were removed after the successful run.

Adversarial coverage included missing fields, invalid repositories, duplicate canonical source, invalid branch, wrong phase, response-loss authorization replay, removed source checkout, noninteractive confirmation, stable key enforcement, malformed response handling, and client SQLite-open tracing.

Prompt injection, cancel or resume lifecycle behavior, dirty Git worktrees, hung external commands, and repeated process interruption belong to later ordered tasks and were not claimed here.

No TUI, merge authorization, automatic execution policy, model advisory authority, direct SQL, direct Mix evaluation by the client, handcrafted socket JSON, automatic GitHub delivery, or PR creation by the product was added.
