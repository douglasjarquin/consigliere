package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"syscall"
	"time"
)

type HarnessHandle struct {
	Cmd    *exec.Cmd
	PID    int
	PGID   int
	Stdout io.ReadCloser
	Stderr io.ReadCloser
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
	cmd.Env = scrubbedHarnessEnv()

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("stdout pipe: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, fmt.Errorf("stderr pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start harness: %w", err)
	}

	pid := cmd.Process.Pid
	deadline := time.Now().Add(confirmTimeout)
	for time.Now().Before(deadline) {
		if pgid, err := syscall.Getpgid(pid); err == nil && pgid == pid {
			return &HarnessHandle{Cmd: cmd, PID: pid, PGID: pgid, Stdout: stdout, Stderr: stderr}, nil
		}
		time.Sleep(time.Millisecond)
	}

	// setsid() never took effect within the window -- an exceptional case
	// this project has never observed happen under normal conditions. The
	// child is still running, but its process group cannot be trusted (it
	// may still be this runner's OWN group), so clean up with a specific-pid
	// signal rather than risk a negative-pgid broadcast against an
	// unconfirmed group. The pid is still returned so a caller that wants to
	// verify the cleanup can do so.
	syscall.Kill(pid, syscall.SIGKILL)
	cmd.Wait()
	return &HarnessHandle{PID: pid}, fmt.Errorf("harness pid %d never completed its own setsid() within %v", pid, confirmTimeout)
}

// scrubbedHarnessEnv is the only environment the harness process is
// allowed to inherit. CS_HOME, credentials, and the daemon's own env
// must not leak (Phase 2 test 12 / threat-model T3). PATH is rebuilt
// so a shebang script can still find sleep/sh; it is not copied from
// the runner.
func scrubbedHarnessEnv() []string {
	env := []string{
		"PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
		"LANG=C",
		"LC_ALL=C",
		"HOME=/var/empty",
		"TMPDIR=" + os.TempDir(),
	}
	if v := os.Getenv("CS_CAPABILITY"); v != "" {
		env = append(env, "CS_CAPABILITY="+v)
	}
	if v := os.Getenv("CS_API_SOCKET"); v != "" {
		env = append(env, "CS_API_SOCKET="+v)
	}
	if v := os.Getenv("CODEX_HOME"); v != "" {
		env = append(env, "CODEX_HOME="+v)
	}
	for _, key := range []string{
		"CS_ATTEMPT_BIN",
		"CS_ATTEMPT_BRIDGE",
		"CS_ATTEMPT_ID",
		"CS_MISSION_ID",
		"CS_PROJECT_ID",
		"CS_WORKSPACE_ID",
		"CS_WORKSPACE_GENERATION",
		"CS_BASE_SHA",
		"CS_PARENT_CHECKPOINT_SHA",
		"CS_FENCING_GENERATION",
		"CS_CAPABILITY_ID",
		"CS_CAPABILITY_GENERATION",
	} {
		if v := os.Getenv(key); v != "" {
			env = append(env, key+"="+v)
		}
	}
	return env
}
