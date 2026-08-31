# Historical exact-head package artifact receipt

Source head: `8010d5fdaa69f9e998b951f8282fddd01e5099ea`.

Command: `scripts/package.sh .tmp/package-final-8010d5f`.

The package command exited `0` and the package-only version response was `{"cs":"0.1.0","protocol":1}`.

The inspected `cs`, `csd`, `cs-runner`, and `cs-attempt` artifacts were native `Mach-O 64-bit executable arm64` files.

SHA-256 values:

```text
cs a065ebb6a24389f12b83a01c537b5c318197f4502f9c53bbab522a9aebc81c68
csd e47abc996450c4b2b6791cea0cc46405e6ffc44c47254d1c2a9c6ecfc31abad6
cs-runner a80912c935bfc1abd133fc74c11f21e7040cd07198e7b45d954182a305be8b02
cs-attempt 1777242a47147a876c2be1d4d59735f5fc4ed47e00312a6143bfd407858e95af
```

The package source scan found no checkout source, Mix project, or Go module files in the release input; OTP migration resources remain part of the release as expected.

The package prefix was moved through `/usr/bin/trash` after lifecycle verification and was verified absent.
