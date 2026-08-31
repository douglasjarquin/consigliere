# Historical exact-head installed lifecycle receipt

Source head: `04940bb620efa47c6d399c056a52a6dff837daf7`.

The package-only `env -i` scenario used fresh home `/tmp/cs-04940bb-home.xKhTxN`, package-only `PATH`, and the release root under `libexec/consigliere_daemon`.

The exercised lifecycle covered migration, start, ping, `cs boss away`, empty mission return, restart, post-restart ping, repeated stop, and final cleanup.

Bounded output was:

```text
migrated /tmp/cs-04940bb-home.xKhTxN/consigliere.db
started home=/tmp/cs-04940bb-home.xKhTxN
pong
{"away":true}
(no missions)
restarted
pong
stopped
stopped
cleanup=ok
package_processes=0
```

The restart used a new daemon owner identity, and repeated stop converged successfully.

The fresh home and package prefix were moved through `/usr/bin/trash` and verified absent.
