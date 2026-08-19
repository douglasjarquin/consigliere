package main

import (
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"syscall"
	"testing"
	"time"
)

// TestMain intercepts a special re-exec invocation of this test binary,
// mirroring the "helper subprocess" idiom Go's own os/exec tests use, so a
// test can spawn a REAL process that calls syscall.Setsid() itself --
// simulating a harness's grandchild that daemonizes and escapes its
// process group -- without depending on tools this test environment may
// not have (there is no `setsid` command on macOS, and this must not
// depend on perl or python being installed).
func TestMain(m *testing.M) {
	switch os.Getenv("CS_RUNNER_TEST_HELPER") {
	case "daemonize":
		syscall.Setsid()
		time.Sleep(60 * time.Second)
		os.Exit(0)
	case "daemonize_ignoring_term_then_fork":
		// os.Args[1] is where to record the pid of a brand-new child this
		// process forks after os.Args[2] milliseconds -- simulating an
		// already-escaped, SIGTERM-resistant descendant that spawns
		// something new well into a termination sequence already in
		// progress, rather than before it ever started.
		syscall.Setsid()
		signal.Ignore(syscall.SIGTERM)
		delayMS, _ := strconv.Atoi(os.Args[2])
		time.Sleep(time.Duration(delayMS) * time.Millisecond)
		child := exec.Command("sleep", "30")
		if err := child.Start(); err == nil {
			os.WriteFile(os.Args[1], []byte(strconv.Itoa(child.Process.Pid)), 0o644)
		}
		time.Sleep(60 * time.Second)
		os.Exit(0)
	}
	os.Exit(m.Run())
}
