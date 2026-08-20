#!/usr/bin/env python3
"""Hold an exclusive fcntl lock until stdin closes or the parent dies."""

import fcntl
import os
import select
import sys

path = sys.argv[1]
parent = os.getppid()

try:
    import ctypes
    import signal

    ctypes.CDLL(None).prctl(1, int(signal.SIGTERM))
    if os.getppid() != parent:
        sys.exit(0)
except Exception:
    pass

fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
lock = fcntl.LOCK_EX | fcntl.LOCK_NB
try:
    fcntl.flock(fd, lock)
except BlockingIOError:
    sys.stdout.write("locked\n")
    sys.stdout.flush()
    sys.exit(2)

os.fchmod(fd, 0o600)
sys.stdout.write("ok\n")
sys.stdout.flush()

stdin = sys.stdin.fileno()
while True:
    if os.getppid() != parent:
        break
    ready, _, _ = select.select([stdin], [], [], 0.25)
    if ready:
        if os.read(stdin, 1) == b"":
            break
