package main

import (
	"os"
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
	if os.Getenv("CS_RUNNER_TEST_HELPER") == "daemonize" {
		syscall.Setsid()
		time.Sleep(60 * time.Second)
		os.Exit(0)
	}
	os.Exit(m.Run())
}
