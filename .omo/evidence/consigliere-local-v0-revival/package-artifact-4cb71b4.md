# Exact-head package artifact receipt

Source head: `4cb71b41075631d8beb30ddaeca5171c9b835234`.

Command: `scripts/package.sh .tmp/package-final-4cb71b4`.

Exit status: `0`.

The installed `cs`, `csd`, `cs-runner`, and `cs-attempt` artifacts were native arm64 Mach-O files.

SHA-256 values:

```text
cs 8e8256ae254e2ecbaa964e8528443bbd87095049fa421a018dc39a01dfb83529
csd 956c78791b78b6ec37658a4998161311d9acbe7371db25ac4c552c6287b67a21
cs-runner d4f3aa9f1533b484b500b3f0a199a217c23e52122ec6e9036d8ca468cffa5533
cs-attempt 68475912c9a3a2635481434303b7f34ac0be47eb47154a12fde1e916dedf4d7d
```

The package source-like-file scan was bounded to the release tree and found only OTP release migration resources, with no checkout source, Mix project, or Go module files.

The package prefix was moved through `/usr/bin/trash` after the package-only lifecycle passed and was verified absent.
