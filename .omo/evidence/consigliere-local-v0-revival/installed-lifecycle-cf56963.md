# Exact-head installed lifecycle receipt

Source head: `cf56963a7206e5c5a260442c08eaa7bdcd65ec7a`.

The package-only `env -i` scenario used fresh `CS_HOME=/tmp/cs-cf56963-r2-home.x6XQV1`, package-only `PATH`, and the release root under `libexec/consigliere_daemon`.

The exercised lifecycle covered migration, start, ping, `cs boss away`, empty boss return, restart, post-restart ping, repeated stop, stopped-status verification, and final cleanup.

Bounded output was:

```text
{"cs":"0.1.0","protocol":1}
migrated /tmp/cs-cf56963-r2-home.x6XQV1/consigliere.db
started home=/tmp/cs-cf56963-r2-home.x6XQV1
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

The fresh home and package prefix were moved through `/usr/bin/trash` and verified absent.
