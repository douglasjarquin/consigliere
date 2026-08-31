# Historical exact-head installed lifecycle receipt for f064f4f

Source head: `f064f4f79d9865c27c083e2dbf47e039cbe09c3f`.

The installed-only lifecycle used a fresh `/tmp` home, `env -i`, the package-only PATH, migration, start, ping, Away, restart, post-restart ping, stop, repeated stop, and status-after-stop.

Bounded result:

    {"cs":"0.1.0","protocol":1}
    migrated /tmp/cs-f064-home.X95NBf/consigliere.db
    started home=/tmp/cs-f064-home.X95NBf
    pong
    {"away":true}
    (no missions)
    restarted
    pong
    stopped
    stopped
    home=/tmp/cs-f064-home.X95NBf priv=absent api=absent boss=absent lock=stale holder=0 owner=absent
    status_after_stop_rc=3
    package_processes=0
    cleanup_home_present=0

The stale lock report had no holder, and the fresh lifecycle home was moved through the supported safe path after all assertions passed.
