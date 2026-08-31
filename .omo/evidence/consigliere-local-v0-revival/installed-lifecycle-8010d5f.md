# Historical exact-head installed lifecycle receipt

Source head: `8010d5fdaa69f9e998b951f8282fddd01e5099ea`.

The package-only `env -i` scenario used fresh home `/tmp/cs-8010d5f-home.D2r10u`, package-only `PATH`, and the release root under `libexec/consigliere_daemon`.

The exercised lifecycle covered migration, start, ping, `cs boss away`, empty mission return, restart, post-restart ping, repeated stop, and final cleanup.

Bounded output was:

```text
migrated /tmp/cs-8010d5f-home.D2r10u/consigliere.db
started home=/tmp/cs-8010d5f-home.D2r10u
pong
{"away":true}
(no missions)
restarted
pong
stopped
stopped
status_after_stop_rc=3
package_processes=0
cleanup=ok
```

The restart used a new daemon owner identity, repeated stop converged, and the expected stopped status returned exit code `3`.

The fresh home and package prefix were moved through `/usr/bin/trash` and verified absent.
