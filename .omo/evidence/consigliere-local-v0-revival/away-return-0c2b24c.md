# Exact-head Away marker and cursor race receipt

Source head: `0c2b24c02490c8f6f53b7f6bc1a9fb9add519861`.

Away return acknowledges the durable cursor only for the exact marker snapshot and removes the filesystem marker only when its token still matches that snapshot.

The stale-marker regression and overlapping-return regression passed in the six-test Away cursor suite for five consecutive seeds.

The focused Away and termination boundary suite passed `25 tests`.

The complete daemon suite passed `510 passed (1 doctest, 509 tests)` after format and warnings-as-errors compilation.
