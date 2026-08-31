# Historical exact-head Away return boundedness receipt

Source head: `4cb71b41075631d8beb30ddaeca5171c9b835234`.

The tests-first RED command was `MIX_ENV=test mix test test/consigliere/away_cursor_test.exs:47 --no-color --seed 0`.

The RED result was `0/1 passed` because the oversized event payload remained in the returned digest.

The implementation bounds Questions, Missions, and event rows to 32 deterministic records, redacts and bounds human text, omits raw domain-event payloads, validates the encoded digest before acknowledgement, and propagates typed acknowledgement or response-size errors.

The focused GREEN command was `mix test test/consigliere/away_cursor_test.exs test/consigliere/away_test.exs test/consigliere/api_protocol_test.exs --no-color --seed 0`.

The focused GREEN result was `14 passed`.

Five repeated combined reader and Away runs each returned `15 passed, 8 excluded`.

The full daemon command used `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `MIX_ENV=test mix test --no-color --seed 0`.

The full daemon result was `503 passed (1 doctest, 502 tests)` with exit status `0`.

The exact package command was `scripts/package.sh .tmp/package-final-4cb71b4` with exit status `0`.

The package version was `{"cs":"0.1.0","protocol":1}`.

The package binaries were native arm64 Mach-O files with these SHA-256 values:

```text
cs 8e8256ae254e2ecbaa964e8528443bbd87095049fa421a018dc39a01dfb83529
csd 956c78791b78b6ec37658a4998161311d9acbe7371db25ac4c552c6287b67a21
cs-runner d4f3aa9f1533b484b500b3f0a199a217c23e52122ec6e9036d8ca468cffa5533
cs-attempt 68475912c9a3a2635481434303b7f34ac0be47eb47154a12fde1e916dedf4d7d
```

The package-only lifecycle used `env -i`, a fresh `/tmp/cs-4cb71b4-home.D1ggSd`, and `CS_RELEASE` set to the OTP release root under `libexec/consigliere_daemon`.

The observed bounded output was `pong`, `{"away":true}`, `(no missions)`, `restarted`, `pong`, `stopped`, `stopped`, and `cleanup=ok`.

The final cleanup moved the fresh home and `.tmp/package-final-4cb71b4` through `/usr/bin/trash` and verified both paths were absent.

The final package-process scan reported `package_processes=0`.

The adversarial regression used an oversized secret-shaped domain-event payload and verified that the payload did not cross the Away response boundary.

The stale-cursor and response-size failure path is guarded by source-level ordering and `Limits.encoded_size/1` before `ack_cursor/0`.

No Mission, Attempt, canary, FirstMate run, Made daemon, push, PR, or merge was created by this follow-up.
