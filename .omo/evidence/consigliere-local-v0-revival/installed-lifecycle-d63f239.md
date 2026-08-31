# Exact-head installed lifecycle receipt

Runtime source head: `d63f2390944a534f4746c64ef60e43332fd546c3`.

The installed-only driver used `env -i`, a fresh temporary `CS_HOME`, only the package `PATH`, and the packaged `cs`, `csd`, and OTP release.

Commands and bounded results:

    csd migrate -> exit 0
    csd start -> exit 0
    cs ping -> pong, exit 0
    cs doctor -> exit 0, live lock and sockets reported
    csd stop -> stopped, exit 0
    csd restart -> restarted, exit 0
    cs ping -> pong, exit 0
    csd stop -> stopped, exit 0
    csd stop -> stopped, exit 0

The final process scan reported `package_processes=0`.

The temporary package prefix and QA home were moved through `/usr/bin/trash` and verified absent.
