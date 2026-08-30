# Final manual QA report

Verdict: PASS for the installed Consigliere package at exact source head `7c54c782552f3ee5a09ddee35735e90cba1b9339`.

The retained package was `.tmp/package-7c54c78.YzUATZ`.

No product files were changed.

The report is bounded and redacts temporary absolute paths as `<PACKAGE_ROOT>`, `<QA_ROOT>`, and `<PID-A>/<PID-B>`.

## Invocation boundary

The lifecycle working directory was `/tmp`, outside the checkout.

The exact environment invocation was:

```text
cd /tmp
env -i PATH=<PACKAGE_ROOT>/bin:/usr/bin:/bin HOME=<QA_ROOT>/home CS_HOME=<QA_ROOT>/cs CS_RELEASE=<PACKAGE_ROOT>/libexec/consigliere_daemon CS_CSD_FORCE_BACKGROUND=1 LANG=C /bin/bash -s
```

The script supplied to that shell invoked only the commands listed in the `surfaceEvidence` matrix.

The fresh HOME and CS_HOME were created below `/tmp` and were moved to macOS Trash after the final stop.

## manualQa

### surfaceEvidence

| scenario id | criterion reference | surface | exact invocation | verdict | artifactRefs |
| --- | --- | --- | --- | --- | --- |
| SHA-01 | exact full SHA and retained package | checkout identity and package path | `git rev-parse HEAD`; `test -d .tmp/package-7c54c78.YzUATZ` | PASS | A-PKG |
| PKG-01 | package-only executable boundary | package `bin` and package tree | `/usr/bin/find <PACKAGE_ROOT>/bin -maxdepth 1 -type f -print`; `/usr/bin/find <PACKAGE_ROOT> -type f \( -name '*.go' -o -name '*.ex' -o -name 'mix.exs' -o -name 'mix.lock' -o -name 'go.mod' \) -print` | PASS | A-PKG, A-BOUNDARY |
| LIFE-01 | version | installed client | `cs version --json` | PASS | A-TRANSCRIPT |
| LIFE-02 | migrate | installed daemon control | `csd migrate` | PASS | A-TRANSCRIPT |
| LIFE-03 | start, ping, and health | installed daemon and client probe surfaces | `csd start`; `cs ping`; `cs health` | PASS | A-TRANSCRIPT |
| LIFE-04 | doctor and status | installed diagnostics and owner status surfaces | `cs doctor`; `csd status` | PASS | A-TRANSCRIPT |
| LIFE-05 | repeated stop and cleanup of runtime handles | installed daemon control and CS_HOME filesystem | `csd stop`; `csd stop`; `/usr/bin/find <QA_ROOT>/cs \( -type s -o -name '*.pid' -o -name '*.owner' \) -print` | PASS | A-TRANSCRIPT |
| LIFE-06 | restart with changed verified owner | installed daemon control and status surface | `csd restart`; `cs ping`; `cs health`; `cs doctor`; `csd status` | PASS | A-TRANSCRIPT |
| LIFE-07 | final cleanup | macOS Trash and filesystem boundary | `csd stop`; `csd stop`; `/usr/bin/trash <QA_ROOT>/home <QA_ROOT>/cs`; `/usr/bin/trash <QA_ROOT>` | PASS | A-TRANSCRIPT |
| BOUNDARY-01 | no source, Mix, legacy supervisor, shared Made, or canary runtime usage | package tree, package-owned processes, and lifecycle invocation log | `/usr/bin/find`; `/bin/ps -axo pid=,command=` filtered to `<PACKAGE_ROOT>`; forbidden invocation scan | PASS | A-BOUNDARY, A-TRANSCRIPT |

Observed outputs were as follows.

- `cs version --json` returned `{"cs":"0.1.0","protocol":1}` with exit code 0.
- `csd migrate` completed all migrations and reported `migrated <QA_ROOT>/cs/consigliere.db` with exit code 0.
- `csd start` reported `started home=<QA_ROOT>/cs` with exit code 0.
- Both ping probes returned `pong` with exit code 0.
- Both health probes returned `status=ok protocol=1 release=0.1.0 schema=2.026083012e+13 harness=Consigliere.Harness.Codex` with exit code 0.
- Both doctor probes completed the home, database, lock, credentials, sockets, release, schema, harness, and runner checks with exit code 0.
- The first status reported `priv=live api=live boss=live lock=held holder=<PID-A> owner=verified` with exit code 0.
- The post-restart status reported `priv=live api=live boss=live lock=held holder=<PID-B> owner=verified` with exit code 0.
- The captured numeric holders differed, proving `owner_changed=YES`.
- Both stop calls in the first repeated-stop sequence returned exit code 0 and the socket/PID/owner filesystem check was empty.
- Both final stop calls returned exit code 0 and the final socket/PID/owner filesystem check was empty.

### adversarialCases

| scenario id | criterion reference | adversarial class | expected behavior | verdict | artifactRefs |
| --- | --- | --- | --- | --- | --- |
| ADV-01 | fresh isolated state | empty HOME and CS_HOME | Migration creates only the disposable local database and the daemon starts from that state. | PASS | A-TRANSCRIPT |
| ADV-02 | repeated stop | idempotent shutdown | A second stop succeeds and leaves no socket, PID, or owner files. | PASS | A-TRANSCRIPT |
| ADV-03 | restart ownership | stale or changed owner identity | Restart reacquires a verified owner with a different holder from the first run. | PASS | A-TRANSCRIPT |
| ADV-04 | package/runtime boundary | source or legacy supervisor leakage | Package-owned runtime processes are under the retained package only, with no package-owned legacy supervisor process. | PASS | A-BOUNDARY, A-TRANSCRIPT |
| ADV-05 | shared Made and canary boundary | accidental shared Made or duplicate canary use | No shared Made process or canary operation is invoked by this lifecycle. | PASS | A-BOUNDARY, A-TRANSCRIPT |
| ADV-06 | prohibited external mutation | Mission, Attempt, PR, or merge side effect | No Mission, Attempt, duplicate canary, PR, merge, or boss-decision command is invoked. | PASS | A-TRANSCRIPT |

The package contains six application-owned files whose names include `Made`, including `Consigliere.Made.*` BEAM modules and `priv/fake_made.sh`.

This is recorded as package content, not treated as absence of the internal implementation.

The PASS for ADV-05 is specifically bounded to no shared Made daemon or Made operation being used.

### artifactRefs

| id | kind | description | path |
| --- | --- | --- | --- |
| A-PKG | identity evidence | Full SHA, retained package presence, package bin surface, and source/Mix filename scan. | `.omo/evidence/consigliere-local-v0-revival/manual-qa-final-7c54c78-package.txt` |
| A-TRANSCRIPT | lifecycle transcript | Redacted exact command sequence, outputs, return codes, owner transition, process observations, and cleanup receipt. | `.omo/evidence/consigliere-local-v0-revival/manual-qa-final-7c54c78.transcript.txt` |
| A-BOUNDARY | boundary evidence | Redacted package tree and package-owned process checks, including the internal Made-content caveat. | `.omo/evidence/consigliere-local-v0-revival/manual-qa-final-7c54c78-boundary.txt` |

## Cleanup receipt

`/usr/bin/trash <QA_ROOT>/home <QA_ROOT>/cs` returned 0.

The HOME and CS_HOME paths were absent after Trash.

`/usr/bin/trash <QA_ROOT>` returned 0.

The QA root was absent after Trash.

The raw unredacted transcript was also moved to macOS Trash and verified absent.

No Mission, Attempt, duplicate canary, PR, merge, or shared Made operation was created or invoked.
