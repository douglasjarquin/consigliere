# Session start and lock

## Sub-features

- Session start resolves the home, checks dependencies, loads the operating digest, and reconciles durable state.
- The session lock prevents two active Consigliere roots from mutating the same fleet state.
- Harness selection is auto-detected unless `host/harness.conf` pins it.
- Turn-end hooks preserve supervision and prevent a checkpoint loop from trapping the session.

## How to get to it (user POV)

Launch Consigliere from the repo inside a herdr pane and let `bin/cs-session-start.sh` complete before giving it work.

If the lock is refused, keep the session read-only and resolve the existing home rather than starting a second fleet supervisor.

## Driving it

- `bin/cs-session-start.sh` owns the ordered startup digest and its one-time invocation contract.
- `bin/cs-sessionstart-run.sh` owns the guarded run and completion proof used by the harness entry path.
- `bin/cs-lock.sh` and `bin/cs-lock-lib.sh` own acquisition and fail-closed lock checks.
- `docs/configuration.md`, `docs/codex.md`, `docs/claude.md`, and `docs/herdr.md` own layout and verified runtime facts.

## Gotchas

- A session-start lock refusal is a read-only safety state, not permission to dispatch or repair fleet state.
- The session digest is the current operational picture, while status files remain wake events rather than reconciled truth.
- Do not manually reconstruct startup commands from memory when the script header owns their composition.
