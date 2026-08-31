# Exact-head installed lifecycle receipt

Source head: `0fd7d3b951672df7cb37e6c160401d1593386ba2`.

The package-only `env -i` scenario used fresh `CS_HOME=/tmp/cs-0fd7d3b-home.oWgqHr`, package-only `PATH`, and the release root under `libexec/consigliere_daemon`.

The exercised lifecycle covered migration, start, ping, `cs boss away`, empty boss return, restart, post-restart ping, repeated stop, and final cleanup.

Bounded output was:

```text
migrated /tmp/cs-0fd7d3b-home.oWgqHr/consigliere.db
started home=/tmp/cs-0fd7d3b-home.oWgqHr
pong
{"away":true}
(no missions)
restarted
pong
stopped
stopped
status_after_stop_rc=3
package_processes=0
cleanup_home_present=0
```

Restart used a new daemon owner identity, repeated stop converged, and the expected stopped status returned exit code `3`.

The fresh home was moved through `/usr/bin/trash` and verified absent.
