# Installed package lifecycle at exact source head

Date: 2026-08-30.

Source: `71593738cf6aae723c9208743405fa12a9dc7a03` on `revival/v0-local-codex`.

The package-only driver used `env -i`, a fresh temporary `CS_HOME=/tmp/cs-v0-7159373-home.WFYSpT`, the package release root, `CS_CSD_FORCE_BACKGROUND=1`, and no source checkout or Mix access.

The bounded command sequence was:

```text
cs version --json
csd migrate
csd start
cs ping
cs health
cs doctor
csd status
csd stop
csd stop
csd restart
cs ping
cs health
cs doctor
csd status
csd stop
csd stop
```

Every command exited `0`.

The first verified owner PID was `16340` and the restart owner PID was `16417`; owner identity changed across restart.

The bounded health/status observations were `ping=pong`, `owner=verified`, `status=ok`, protocol `1`, release `0.1.0`, schema `2.026083012e+13`, harness `Consigliere.Harness.Codex`, and runner present.

The final assertions reported `OLD_OWNER=absent`, `RESTART_OWNER=absent`, and `RESIDUE=none`.

The temporary home and output files were moved to macOS Trash with `/usr/bin/trash`, then absence was verified.
