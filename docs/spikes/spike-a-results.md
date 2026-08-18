# Spike A results: SQLite serialized writer

Status: done, all seven scenarios from `docs/phase0-report.md` section 10 pass.

This spike proves `Consigliere.DatabaseWriter`, a single GenServer that routes every write through one mailbox into a short `Repo.transaction/1`, is a safe and sufficient foundation for the daemon's single-serialized-write-path rule (ADR-002). It also proves SQLite's WAL mode, `busy_timeout`, `VACUUM INTO` backup, and crash recovery behave as the architecture docs assume, on this machine, with the actual toolchain the daemon will run.

## What was built

`daemon/` at the root of this repo: a plain (non-umbrella) Elixir/OTP application (`consigliere_daemon`, module prefix `Consigliere`), with:

- `Consigliere.Repo` (Ecto, `ecto_sqlite3`/`exqlite` adapter, WAL journal mode, 5s `busy_timeout`).
- `Consigliere.DatabaseWriter`, the single serialized write path. Holds no domain state; every call is `Repo.transaction/1`.
- `Consigliere.Missions.Mission`, a minimal schema (just enough fields to give the spike a real table), and its migration.
- `Consigliere.Application`, a `:one_for_one` supervisor over `Repo` and `DatabaseWriter`.
- `test/consigliere/database_writer_test.exs`: ExUnit coverage for scenarios 1-4 and 6.
- `spike_scripts/crash_writer.exs`, `spike_scripts/verify_after_crash.exs`, `spike_scripts/backup_scenario.exs`: standalone `mix run` scripts for scenarios 5 and 7, which need real OS-level process control (`kill -9`) or independent file inspection that ExUnit's in-process model can't exercise.

## Toolchain notes (this machine)

Elixir 1.20.3 / Erlang-OTP 29 were already installed via Homebrew from the earlier, since-discarded spike attempt. Erlang is keg-only; `erl` is not on `PATH` by default and needs `export PATH="/opt/homebrew/opt/erlang/bin:$PATH"` before running `mix` in a fresh shell. `mix local.hex --force` / `mix local.rebar --force` were re-run to make sure Hex/rebar match OTP 29; `exqlite`'s native extension compiled cleanly against it.

## Results by scenario

1. **Concurrent writers, no `SQLITE_BUSY`.** 25 concurrent writers: all 25 commit, zero errors, exact row count. 200 concurrent writers: all 200 commit, zero errors, exact row count. Both via ExUnit (`mix test`).
2. **Concurrent reads during writes.** 50 concurrent readers running alongside a 25-writer burst all complete successfully; none blocked by, or block, the write path (WAL mode's expected reader/writer concurrency). Via ExUnit.
3. **`busy_timeout` under contention.** A transaction deliberately held open 300ms while a second write queues behind it: the queued write succeeds once the first commits, and the `DatabaseWriter` process is still alive afterward. Via ExUnit.
4. **WAL checkpoint.** `PRAGMA wal_checkpoint(TRUNCATE)` after a 25-write burst returns cleanly; row count is unaffected. Via ExUnit.
5. **Crash recovery.** A standalone `mix run` process (`crash_writer.exs`) was launched writing in a tight loop, `kill -9`'d after 3 seconds (confirmed dead via `ps -p`, no orphaned `beam.smp` process left behind), having gotten through roughly 27,050 writes by its own log. A second, independent `mix run` process then confirmed: `PRAGMA integrity_check` returns `ok`; exactly 27,056 `crash-test-*` rows are present; zero rows have a null `phase` or `inserted_at` (the torn-row check). No partial/corrupted state survived the kill.
6. **Poison-row quarantine.** A row with `phase = "not_a_real_phase_value"` (a value SQLite's schema does not, and at this layer should not, reject, since phase-enum validity is an application-level invariant, not a database constraint) was inserted via raw SQL, bypassing the Ecto changeset. The `DatabaseWriter` process stayed alive and continued accepting normal writes afterward. This proves the writer itself is resilient to a single bad row; the reconciler that would actually classify and quarantine such a row at the Mission level is Phase 1/2 work, not this spike's job.
7. **`VACUUM INTO` backup and restore, plus the negative control.** After a 500-row burst (27,556 total rows, not yet WAL-checkpointed), `VACUUM INTO` produced a backup file that, opened independently via the `sqlite3` CLI (a process with zero shared state with the live database), passed `PRAGMA integrity_check` and reported the exact same row count (27,556). A plain `File.cp!` of only the live `.db` file, taken at the same moment and ignoring its `-wal` sidecar, reported only 27,192 rows when opened independently: 364 committed rows silently missing, because they lived in the WAL file the plain copy never touched. This is the concrete, reproduced proof behind the warning in `docs/architecture/database.md`: never back up by copying only the live `.db` file.

## Exit criteria (from `docs/phase0-report.md` section 10)

All seven scenarios pass; scenario 6 in particular proves the daemon can survive a single invalid row without a full restart-crash-loop (invariant 21). Spike A is done.

## What this spike does not prove yet

This spike says nothing about the runner, coordinator-independent supervision, daemon-bound process termination, agent isolation, or packaging; those are Spikes B through E and remain not started. The Mission schema here is intentionally minimal (title, phase only) and is not the Phase 1 schema; `docs/state-machines/mission.md` and `docs/architecture/database.md` remain the source of truth for the real field list.
