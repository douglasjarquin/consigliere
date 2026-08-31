# Exact-head installed lifecycle receipt

Source head: `eb41191b73a04b93d613d8d0cf8b2183a55272ef`.

The package-only `env -i` scenario used fresh `/tmp` homes and exercised version, migration, start, ping, health, `cs projects`, `cs review`, doctor, verified status, repeated stop, restart, post-restart ping, reader projections, doctor, verified status, repeated stop, and cleanup.

Bounded observations:

```text
version={"cs":"0.1.0","protocol":1}
projects=(no projects)
review=
status=owner=verified
stop1=stopped
stop2=stopped
restart=restarted
ping_after_restart=pong
projects_after_restart=(no projects)
review_after_restart=
status_after_restart=owner=verified
stop3=stopped
stop4=stopped
cleanup=ok
```

The two verified owner observations used different holder PIDs, and final sockets, PID files, and owner files were absent.

The package prefix and fresh homes were moved to macOS Trash.
