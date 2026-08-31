# Historical exact-head package artifact receipt

Source head: `04940bb620efa47c6d399c056a52a6dff837daf7`.

Command: `scripts/package.sh .tmp/package-final-04940bb`.

The package command exited `0` and returned `{"cs":"0.1.0","protocol":1}` from the packaged `cs version --json` command.

The inspected `cs`, `csd`, `cs-runner`, and `cs-attempt` artifacts were native `Mach-O 64-bit executable arm64` files.

SHA-256 values:

```text
cs e64255812e7a943c0f3b49e3c4b0248eb0ca90aa1fb5fe1c7a2aefec3555d9df
csd 95fd84b0beff3dd771c218192ae2e7ff6aea63b84a9d76efd4aa81e0d3f19dd2
cs-runner 5f59996f0ea8aec8faed720d41d3c48af9a567fc8fdaa0636ac27875a08e04b9
cs-attempt c98160127d53e7e694b0bcf530d5fdef45e73dbab5304388e0da6ccffb712d65
```

The package source scan found no checkout source, Mix project, or Go module files in the release input; OTP migration resources remain part of the release as expected.

The package prefix was moved through `/usr/bin/trash` after lifecycle verification and was verified absent.
