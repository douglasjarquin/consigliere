# Package artifact at exact source head

Date: 2026-08-30.

Target source head: `7c54c782552f3ee5a09ddee35735e90cba1b9339` on `revival/v0-local-codex`.

The package command was:

```text
PATH="/opt/homebrew/opt/erlang/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH" scripts/package.sh .tmp/package-7c54c78.YzUATZ
```

The command exited `0`.

Package prefix: `.tmp/package-7c54c78.YzUATZ`.

The four shipped product executables and the OTP launcher were all reported as native `Mach-O 64-bit executable arm64` files.

The SHA-256 identities were:

| artifact | SHA-256 |
| --- | --- |
| `bin/cs` | `1dcdc89b6159711cae2a376af5b347cfd0a5a8afcbde476cc9502abc340b0433` |
| `bin/csd` | `7c7ce1075a9ef9d55e3c0907ed5571c932d519a6ab9deb65699c9bc0c3a882c4` |
| `libexec/consigliere_daemon/lib/consigliere_daemon-0.1.0/priv/cs-runner` | `690d581a134c8315c3fedc1d73dd9feebb6d850ae2cc822df5322b0980508202` |
| `libexec/consigliere_daemon/lib/consigliere_daemon-0.1.0/priv/cs-attempt` | `409aeae9f2d413fe3f437172dc48dbade4f56b867c12a9e5dfed88267c455245` |
| `libexec/consigliere_daemon/erts-17.0.5/bin/erlexec` | `0d58107509b1c59399cf3c9bdbf495b2f05f1fb4a5492c19cb886c65fb4c96d6` |

The installed `cs version --json` response was `{"cs":"0.1.0","protocol":1}`.

The package tree contained zero `.go`, `.ex`, `mix.exs`, `mix.lock`, or `go.mod` source-like files.

The package was exercised through an `env -i` package-only lifecycle from `/tmp` in `installed-lifecycle-7c54c78.md`.

No legacy Bash supervisor, source checkout, Mix project, or shared Made daemon was used by the installed proof.

Verdict: PASS.
