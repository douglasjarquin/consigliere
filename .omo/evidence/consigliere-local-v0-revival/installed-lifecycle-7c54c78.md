# Installed package lifecycle at exact source head

Date: 2026-08-30.

Target source head: `7c54c782552f3ee5a09ddee35735e90cba1b9339` on `revival/v0-local-codex`.

Package input: `.tmp/package-7c54c78.YzUATZ`.

The driver used `env -i`, package-only `PATH`, a fresh temporary `HOME` and `CS_HOME`, `CS_RELEASE` set to the package release root, `CS_CSD_FORCE_BACKGROUND=1`, and a working directory of `/tmp`.

The exact product sequence was:

```text
cs version --json
csd migrate
csd start
cs ping
cs health
cs doctor
csd status
cs projects
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

The version response was `{"cs":"0.1.0","protocol":1}`.

The live probes returned `pong`, `status=ok`, and `owner=verified`.

The first verified owner holder was PID `71136`.

The restart acquired verified owner PID `71283`, proving that the owner identity changed across restart.

The first repeated-stop sequence left zero sockets, PID files, and owner files before restart.

The final receipt was `F3_INSTALLED_LIFECYCLE stop=verified sockets=0 pid_files=0 owner_files=0 package_processes=0 holder_before=71136 holder_after=71283`.

The temporary homes were moved to macOS Trash with `/usr/bin/trash`, and absence was verified.

The migration emitted normal schema progress and one transient SQLite lock initialization log, but migration completed and every product command succeeded.

No source checkout, Mix, legacy Bash supervisor, shared Made daemon, Mission, Attempt, or canary invocation occurred in this lifecycle lane.

Verdict: PASS.
