# Historical exact-head installed lifecycle receipt

Source head: `4cb71b41075631d8beb30ddaeca5171c9b835234`.

The package-only `env -i` scenario used fresh `/tmp/cs-4cb71b4-home.D1ggSd`, package-only `PATH`, and `CS_RELEASE` set to the OTP release root under `libexec/consigliere_daemon`.

The exercised sequence was `csd migrate`, `csd start`, `cs ping`, `cs boss away`, `cs boss return`, `csd restart`, `cs ping`, repeated `csd stop`, and final socket, PID, owner, and package-process checks.

Bounded output was:

```text
version={"cs":"0.1.0","protocol":1}
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
