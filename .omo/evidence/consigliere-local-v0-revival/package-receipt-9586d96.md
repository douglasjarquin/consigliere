# Package and lifecycle receipt for `9586d96411e068b87de26c6de8e38877f951e3e8`

The package was built from the exact source head with `./scripts/package.sh` into a disposable absolute prefix.

The package prefix was `/tmp/cs-package-final-9586d96.wVgmEM` and was moved to macOS Trash after the lifecycle proof.

## Artifact hashes

```text
73a5b4ec9bcddce79f689d8f7d1f1ca75a98fa7ecaf7896a9b0923a5d11e6292  /tmp/cs-package-final-9586d96.wVgmEM/bin/cs
14e81be73bedd7dd462437dbbb44859d9e8e9f16a80dcbafc31bce999fe9635c  /tmp/cs-package-final-9586d96.wVgmEM/bin/csd
58444bc4a843dfdaeeb64a7a9f85c8fb3175940514b8dbab8f28d66d887e368c  daemon/priv/cs-attempt
2316ca56cacebe8f6524b04eb2772f0d96028bc87fcc2b1f14e7ed8771ba18a8  daemon/priv/cs-runner
```

The hash command was `shasum -a 256 <package>/bin/cs <package>/bin/csd daemon/priv/cs-attempt daemon/priv/cs-runner`.

## Installed lifecycle receipt

The lifecycle ran with `env -i`, only the package `bin` directory and `/usr/bin:/bin` on `PATH`, a fresh `HOME`, a fresh `CS_HOME`, `CS_RELEASE` set to the installed release, and `CS_CSD_FORCE_BACKGROUND=1`.

The bounded command sequence was `cs version --json`, `csd migrate`, `csd start`, `cs ping`, `cs health`, `cs doctor`, `csd status`, `csd stop`, repeated `csd stop`, `csd restart`, `cs ping`, `cs health`, `cs doctor`, `csd status`, `csd stop`, and repeated `csd stop`.

The first owner PID was `61511` and the restart owner PID was `61834`.

```text
LIFECYCLE=stopped sockets=0 pid_files=0 owner_files=0 package_processes=0
CLEANUP=trashed home_environment_package
```

The complete bounded driver output was captured at `/tmp/package-lifecycle-final-9586d96.log` during QA and the package prefix, QA home, and environment directory were all moved to macOS Trash.
