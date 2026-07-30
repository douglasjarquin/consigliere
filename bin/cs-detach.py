#!/usr/bin/env python3
"""Start a command in its own session, so it outlives whoever launched it.

Why this exists: `nohup cmd & disown` survives SIGHUP but NOT the teardown of
the launching process group. Consigliere launches its persistent monitor from
inside an agent's bounded tool call, and measured over one night the difference
is decisive - a monitor started that way died and was revived 213 times in seven
hours in one home, while the same binary with a surviving parent ran 9h20m
straight and never restarted. Revival papered over the churn at the cost of a
gap between checkpoints, which is exactly the dependency the monitor exists to
remove.

`setsid(2)` is the fix and macOS ships no `setsid` binary, so this does it in
python3 - already a declared consigliere dependency (bin/cs-deps-lib.sh) used on
primary paths including the herdr push-event reader. perl was the other
candidate and was rejected: it appears in this repo only on `command -v`
fallback branches and is declared nowhere, so putting a load-bearing path on it
would depend on a tool doctor never checks for.

Double fork so the child cannot regain a controlling terminal: fork, setsid in
the intermediate, fork again, exec in the grandchild. The parent exits
immediately, so the caller never waits on it.

Usage:
  cs-detach.py [--stdout <path>] [--stderr <path>] -- <command> [args...]

Options:
  --stdout <path>   append the child's stdout here (default: /dev/null)
  --stderr <path>   append the child's stderr here (default: same as --stdout)

Exit status:
  0  the grandchild was started; its pid is printed to stdout
  2  bad arguments
  3  fork/exec failed before the child could start
Nothing about the child's later fate is reported: the caller confirms liveness
through the child's own beacon, never through this exit status.
"""
import os
import sys


def _usage(stream):
    stream.write(
        "usage: cs-detach.py [--stdout <path>] [--stderr <path>] -- <command> [args...]\n"
    )


def main(argv):
    out_path = None
    err_path = None
    i = 1
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            i += 1
            break
        if arg == "--stdout" and i + 1 < len(argv):
            out_path = argv[i + 1]
            i += 2
            continue
        if arg == "--stderr" and i + 1 < len(argv):
            err_path = argv[i + 1]
            i += 2
            continue
        if arg in ("-h", "--help"):
            sys.stdout.write(__doc__)
            return 0
        _usage(sys.stderr)
        return 2
    cmd = argv[i:]
    if not cmd:
        _usage(sys.stderr)
        return 2

    if out_path is None:
        out_path = os.devnull
    if err_path is None:
        err_path = out_path

    # Resolve the read end of the pid handoff before forking, so the parent can
    # report the grandchild's pid without waiting on the child.
    read_fd, write_fd = os.pipe()

    try:
        first = os.fork()
    except OSError:
        os.close(read_fd)
        os.close(write_fd)
        return 3

    if first > 0:
        # Parent: reap the intermediate immediately (it exits at once, so this
        # never blocks for the child's lifetime), then hand back the pid.
        os.close(write_fd)
        try:
            os.waitpid(first, 0)
        except OSError:
            pass
        with os.fdopen(read_fd, "r") as handoff:
            pid = handoff.read().strip()
        if not pid:
            return 3
        sys.stdout.write(pid + "\n")
        return 0

    # Intermediate: become a session leader, so the new process group is no
    # longer part of the launcher's and a group-directed kill cannot reach it.
    os.close(read_fd)
    try:
        os.setsid()
    except OSError:
        pass

    try:
        second = os.fork()
    except OSError:
        os._exit(3)

    if second > 0:
        # Report the grandchild's pid and exit at once, orphaning it to init.
        try:
            with os.fdopen(write_fd, "w") as handoff:
                handoff.write(str(second))
        except OSError:
            pass
        os._exit(0)

    # Grandchild: no controlling terminal, no shared process group. Redirect and
    # exec the real command.
    os.close(write_fd)
    try:
        devnull = os.open(os.devnull, os.O_RDONLY)
        os.dup2(devnull, 0)
        if devnull > 2:
            os.close(devnull)
        out = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        os.dup2(out, 1)
        if out > 2:
            os.close(out)
        if err_path == out_path:
            os.dup2(1, 2)
        else:
            err = os.open(err_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            os.dup2(err, 2)
            if err > 2:
                os.close(err)
    except OSError:
        os._exit(3)

    try:
        os.execvp(cmd[0], cmd)
    except OSError:
        os._exit(3)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
