# Exact-head package artifact receipt

Runtime source head: `d63f2390944a534f4746c64ef60e43332fd546c3`.

Command: `scripts/package.sh "$(mktemp -d)/prefix"`.

Result: exit `0`.

The fresh package produced native macOS arm64 `cs`, `csd`, `cs-runner`, and `cs-attempt` artifacts.

SHA-256 values from the temporary package:

    cs f5ea6dd0e67e34131c0fcf53a574bd7a496eb3a1660f1b2d2c06063740a304ef
    csd 0fd71b6a9073f70f47f8857d32c3666c105867f01b0dd8c29659cb66b679bc48
    cs-runner 7b6cb4325983b18f29f664d7e44e307ac52c86551091ee12256457985f55b900
    cs-attempt 7fdb81e4966e287c0c93d7a700656c8789f93dac94ab26ca3c880080e2111237

The package and its fresh QA home were moved to macOS Trash after all assertions passed.
