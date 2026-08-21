# Consigliere daemon

OTP daemon for Consigliere.
The daily-driver binaries are `cs` (boss client) and `csd` (service wrapper).
Neither opens SQLite.
`cs` talks NDJSON `v=1` to `$CS_HOME/priv.sock` with the boss credential.

## Package

From the repository root:

```sh
./scripts/package.sh /usr/local/consigliere
export PATH="/usr/local/consigliere/bin:$PATH"
export CS_RELEASE=/usr/local/consigliere/libexec/consigliere_daemon
export CS_HOME="$HOME/.consigliere"
csd migrate
csd install
csd start
cs doctor
```

`scripts/package.sh` writes `cs`, `csd`, the OTP release, `cs-runner`, and the cutover runbook into a prefix.
After that, Mix and the source tree are not required.

## `cs`

```
cs health
cs version
cs doctor
cs ping
cs projects
cs project <id>
cs missions
cs mission <id>
cs mission create --project-id ID --objective TEXT --scope TEXT --acceptance TEXT
cs why <mission-id>
cs inbox
cs away
cs return
cs answer <question-id> --text TEXT
cs review
cs authorize-merge <mission-id> --pr N --sha SHA
cs pause <mission-id>
cs resume <mission-id>
cs cancel <mission-id>
cs attempts
cs attempt logs <attempt-id>
cs incidents
cs events
cs reconcile
cs cutover
```

`--json` prints the socket response.
`cs why` renders Mission phase and open blockers, not model prose.
`cs return` acknowledges the AFK cursor.
`cs attempt logs` is a read-only dump of the attempt log file.

## `csd`

```
csd foreground
csd start
csd stop
csd restart
csd status
csd logs
csd migrate
csd install [--prefix DIR] [--no-load]
csd uninstall
```

`csd foreground` execs the OTP release `start` and is what launchd runs.
`csd start` backgrounds that process with a new session (or `launchctl bootstrap` when a LaunchAgent plist is present on macOS).
`csd install` writes `~/Library/LaunchAgents/ai.consigliere.csd.plist` with `CS_HOME`, home-relative logs, `ThrottleInterval` 10, and `KeepAlive` only on unsuccessful exit.
It refuses to run as root.

Database identity is `CS_HOME/consigliere.db`, not the working directory.

## Develop

```sh
export PATH="/opt/homebrew/opt/erlang/bin:$PATH"
cd daemon
mix test
```

Go client:

```sh
cd cli
go test ./...
```
