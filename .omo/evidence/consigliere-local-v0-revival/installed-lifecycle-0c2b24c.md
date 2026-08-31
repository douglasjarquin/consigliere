# Historical superseded exact-head installed lifecycle receipt

Source head: `0c2b24c02490c8f6f53b7f6bc1a9fb9add519861`.

The installed-only lifecycle used a fresh `/tmp` home, `env -i`, the package-only PATH, migration, start, ping, Away, restart, post-restart ping, stop, repeated stop, and status-after-stop.

Bounded result:

    {"cs":"0.1.0","protocol":1}
    migrated /tmp/cs-0c2b24c-home.bqCesZ/consigliere.db
    started home=/tmp/cs-0c2b24c-home.bqCesZ
    pong
    {"away":true}
    (no missions)
    restarted
    pong
    stopped
    stopped
    home=/tmp/cs-0c2b24c-home.bqCesZ priv=absent api=absent boss=absent lock=stale holder=0 owner=absent
    status_after_stop_rc=3
    package_processes=0
    cleanup_home_present=0

The stale lock report had no holder, and the fresh lifecycle home was moved through the supported safe path after all assertions passed.
