# Lavish verified facts

Verified against `lavish-axi` 0.1.43 on 2026-08-02, on macOS (Darwin 25.5.0), using a throwaway artifact in a scratch directory.
Re-verify this file after a `lavish-axi` upgrade; `bin/cs-procevent-lavish.sh` is the only code that depends on these facts.

Everything here is evidence from a real run except the two rows explicitly marked as not reproducible without a human reviewer.

## Why consigliere cares

`lavish-axi poll` is the one external command consigliere needs that BLOCKS indefinitely on a human.
`bin/cs-procevent.sh` supervises it outside the conversational turn; `bin/cs-procevent-lavish.sh` is the thin adapter that owns Lavish-specific identity and result classification.
Neither script may grow a Lavish fact that is not recorded here first.

## Poll interface

```text
$ lavish-axi poll --help
Usage: lavish-axi poll <html-file> [--agent-reply "..."]

This command long-polls indefinitely for queued user prompts and browser-proven
severe layout failures, then returns them to the agent as layout_warnings.
[...] Do not pass --timeout-ms during normal agent use; it is for tests and
debugging only.
```

The adapter therefore registers the plain blocking form with no `--timeout-ms`, so a captured result is a real server-side event and never a timer artifact.

## Streams and exit codes

The structured response goes to **stdout**; the human-facing progress preamble goes to **stderr**.
This is why the runner reads stdout only and discards the child's stderr.

```text
$ lavish-axi poll ./probe.html >out.txt 2>err.txt; echo "rc=$?"
rc=1
$ cat out.txt
error: No active Lavish Editor session for this file
code: NOT_FOUND
help[1]: Run `lavish-axi /.../probe.html` first
$ cat err.txt
[lavish-axi] Long-polling for user feedback or layout_warnings on /.../probe.html. This
stays silent until the user sends feedback, ends the session, or the browser reports
fresh layout_warnings - leave it running. [...]
```

A delivered result exits 0; a missing session exits 1 with the `error:` / `code:` block above on stdout.

## Response shape

Every non-error response opens with a `session:` block whose fields are **indented**:

```text
$ timeout 30 lavish-axi poll ./probe.html --timeout-ms 3000
session:
  file: /.../probe.html
  status: waiting
next_step: "No user feedback arrived before the optional timeout. [...]"
```

```text
$ lavish-axi end ./probe.html
session:
  file: /.../probe.html
  status: ended
$ timeout 30 lavish-axi poll ./probe.html --timeout-ms 3000
session:
  file: /.../probe.html
  status: ended
  ended_by: agent
next_step: "This Lavish Editor session for /.../probe.html has ended. Stop polling. [...]"
```

Because the fields are indented, an anchored `^status:` match never fires and silently reads every ended review as feedback.
The adapter's `session_field` reads the first indented match inside the leading block, which also stops prompt payload text further down the response from forging a session field.

| `status:` value | meaning | verified |
|---|---|---|
| `opened` | returned by `lavish-axi <file>`, not by `poll` | yes, 0.1.43 |
| `waiting` | the optional timeout elapsed with no feedback | yes, 0.1.43 |
| `ended` | the session is over and will produce nothing further | yes, 0.1.43 |
| `feedback` | the human sent feedback | no - needs a human reviewer; upstream firstmate verified it at 0.1.45 |
| `session_ended: true` | the final feedback of a browser `Send & End` | no - needs a human reviewer; documented by `lavish-axi --help` and verified upstream at 0.1.45 |

`ended`, `missing` (the `NOT_FOUND` error above), and `session_ended: true` are the three terminal conditions `bin/cs-procevent-lavish.sh terminal` reports, and the only place Lavish's notion of "ended" is decided.

## A session is keyed on the artifact's realpath

Two different path spellings of one file are ONE session, so they must never become two owners racing destructive polls.

```text
$ ln -sf probe2.html alias2.html
$ lavish-axi poll ./alias2.html --timeout-ms 2000
session:
  file: /.../scratchpad/probe2.html
  status: waiting
$ lavish-axi poll ./../scratchpad/probe2.html --timeout-ms 2000
session:
  file: /.../scratchpad/probe2.html
  status: waiting
```

Both spellings resolved to the same session and reported the canonical `file:`.
This is why the adapter's source id is a hash of the artifact's **realpath**, never of the path string it was given.

## The destructive-read window

The published poll clears queued feedback server-side as it delivers it.
`lavish-axi --help` states the guarantee only for feedback that was never delivered: "If the poll gets killed or times out anyway, just re-run it - queued feedback is never lost."
Nothing restores feedback that was already handed to a process whose output was then lost.

Not re-verified here, because proving it requires a human sending real feedback; upstream firstmate verified it at 0.1.45 and it is the reason the runner captures output to disk before publishing any event.
The consequence is recorded in `bin/cs-procevent-lib.sh`'s durability boundary: never describe this path as at-least-once, no-loss, or lossless.

## Other commands used

- `lavish-axi <file> --no-open` opens or resumes a session without opening a browser window; useful for tests.
- `lavish-axi end <file>` ends a session as the agent; a plain reopen is still allowed afterwards.
- `lavish-axi stop` shuts down the shared background server for the whole machine, so it must never be run to clean up one artifact.
