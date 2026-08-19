package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// waitForFile polls for a file's existence, used to synchronize on a shell
// script having actually executed past a certain point (e.g. having
// installed a trap) rather than guessing with an arbitrary sleep.
func waitForFile(t *testing.T, path string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("ready file %s never appeared within %v", path, timeout)
}

// startGroupedProcess spawns a process with Setsid and waits for the child
// to actually finish calling setsid() (its own pgid becomes its own pid)
// before returning, closing the same startup race a real runner's spawn
// sequence must close: cmd.Start() returns to the parent as soon as fork()
// completes, but the child's own setsid() call happens asynchronously
// afterward, so a signal sent to the intended pgid too early can silently
// miss the child entirely.
func startGroupedProcess(t *testing.T, script string) (pgid int, cmd *exec.Cmd) {
	t.Helper()
	cmd = exec.Command("sh", "-c", script)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		t.Fatalf("start grouped process: %v", err)
	}

	pid := cmd.Process.Pid
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if actualPgid, err := syscall.Getpgid(pid); err == nil && actualPgid == pid {
			return pid, cmd
		}
		time.Sleep(time.Millisecond)
	}

	t.Fatalf("process %d never completed its own setsid() within the timeout", pid)
	return 0, nil
}

func groupHasSurvivors(pgid int) bool {
	err := syscall.Kill(-pgid, 0)
	return err == nil
}

func TestTerminate_CooperativeProcessExitsOnSIGTERM(t *testing.T) {
	pgid, cmd := startGroupedProcess(t, "sleep 30")
	defer cmd.Wait()

	verified, err := Terminate(pgid, 2*time.Second, 2*time.Second)
	if err != nil {
		t.Fatalf("Terminate: %v", err)
	}
	if !verified {
		t.Fatalf("expected verified=true for a cooperative process")
	}
	if groupHasSurvivors(pgid) {
		t.Fatalf("process group %d still has a live member after Terminate reported verified", pgid)
	}
}

func TestTerminate_StubbornProcessRequiresSIGKILL(t *testing.T) {
	readyFile := filepath.Join(t.TempDir(), "trap-installed")
	script := `trap '' TERM; touch ` + readyFile + `; while true; do sleep 0.1; done`
	pgid, cmd := startGroupedProcess(t, script)
	defer cmd.Wait()

	waitForFile(t, readyFile, 2*time.Second)

	start := time.Now()
	verified, err := Terminate(pgid, 500*time.Millisecond, 2*time.Second)
	elapsed := time.Since(start)

	if err != nil {
		t.Fatalf("Terminate: %v", err)
	}
	if !verified {
		t.Fatalf("expected verified=true once SIGKILL takes effect")
	}
	if groupHasSurvivors(pgid) {
		t.Fatalf("process group %d still has a live member after Terminate reported verified", pgid)
	}
	if elapsed < 500*time.Millisecond {
		t.Fatalf("Terminate returned in %v, faster than the graceful timeout it should have waited out before escalating", elapsed)
	}
}

func TestTerminate_AlreadyDeadGroupReportsVerifiedImmediately(t *testing.T) {
	pgid, cmd := startGroupedProcess(t, "true")
	cmd.Wait()
	time.Sleep(100 * time.Millisecond)

	verified, err := Terminate(pgid, 2*time.Second, 2*time.Second)
	if err != nil {
		t.Fatalf("Terminate: %v", err)
	}
	if !verified {
		t.Fatalf("expected verified=true for an already-exited group")
	}
}
