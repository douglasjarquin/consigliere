# Historical exact-head installed lifecycle receipt for ec47784

Source head: `ec47784a801ee8168fae7b249bf3b8342951ae17`.

The installed-only lifecycle used a fresh `/tmp` home, `env -i`, the package-only PATH, migration, start, ping, Away, restart, post-restart ping, stop, repeated stop, and status-after-stop.

Bounded result:

    {"cs":"0.1.0","protocol":1}
    migrated /tmp/cs-ec47784-home.Xd9aBy/consigliere.db
    started home=/tmp/cs-ec47784-home.Xd9aBy
    pong
    {"away":true}
    (no missions)
    restarted
    pong
    stopped
    stopped
    status_after_stop_rc=3
    package_processes=0
    cleanup_home_present=0

The temporary lifecycle home was removed through the supported safe path after all assertions passed.
