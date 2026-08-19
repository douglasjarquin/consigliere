package main

import (
	"fmt"
	"os/exec"
	"syscall"
	"time"
)

type HarnessHandle struct {
	Cmd  *exec.Cmd
	PID  int
	PGID int
}

// SpawnHarness starts the harness command as a new session and process
// group leader, then blocks until the child has actually completed its own
// setsid() call (confirmed via Getpgid) before returning -- closing the
// startup race termination_test.go found: cmd.Start() returns to the parent
// as soon as fork() completes, but the child's setsid() happens
// asynchronously afterward, so trusting the pgid before this confirmation
// can cause a signal sent moments later to silently miss the child.
func SpawnHarness(command []string, confirmTimeout time.Duration) (*HarnessHandle, error) {
	if len(command) == 0 {
		return nil, fmt.Errorf("harness command must not be empty")
	}

	cmd := exec.Command(command[0], command[1:]...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start harness: %w", err)
	}

	pid := cmd.Process.Pid
	deadline := time.Now().Add(confirmTimeout)
	for time.Now().Before(deadline) {
		if pgid, err := syscall.Getpgid(pid); err == nil && pgid == pid {
			return &HarnessHandle{Cmd: cmd, PID: pid, PGID: pgid}, nil
		}
		time.Sleep(time.Millisecond)
	}

	return nil, fmt.Errorf("harness pid %d never completed its own setsid() within %v", pid, confirmTimeout)
}
