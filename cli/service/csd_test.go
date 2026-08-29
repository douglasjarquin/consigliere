package service

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"

	"github.com/douglasjarquin/consigliere/cli/client"
)

func TestPlistBoundedKeepAliveAndLogs(t *testing.T) {
	body := Plist(Label, "/opt/consigliere/bin/csd", "/tmp/cs-home", "/opt/consigliere/libexec/consigliere_daemon")
	for _, need := range []string{
		"foreground",
		"CS_HOME",
		"/tmp/cs-home",
		"CS_RELEASE",
		"ThrottleInterval",
		"<integer>10</integer>",
		"SuccessfulExit",
		"<false/>",
		"logs/csd.stdout.log",
		"logs/csd.stderr.log",
		"WorkingDirectory",
		"RunAtLoad",
		"ProcessType",
		"Background",
	} {
		if !strings.Contains(body, need) {
			t.Fatalf("plist missing %q\n%s", need, body)
		}
	}
	if strings.Contains(body, "root") {
		t.Fatal("plist must not mention root")
	}
	if strings.Contains(body, "UserName") {
		t.Fatal("plist must not set UserName")
	}
}

func TestInstallWritesPlistWithoutLaunchd(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "csc-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	agents := filepath.Join(dir, "LaunchAgents")
	t.Setenv("CS_LAUNCH_AGENTS_DIR", agents)
	t.Setenv("CS_HOME", filepath.Join(dir, "home"))
	t.Setenv("CS_RELEASE", filepath.Join(dir, "rel"))
	home := client.Home{Dir: filepath.Join(dir, "home")}
	if err := Install(home, "", true); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(PlistPath())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), "foreground") {
		t.Fatalf("bad plist: %s", body)
	}
	if !strings.Contains(string(body), home.Dir) {
		t.Fatalf("plist missing CS_HOME: %s", body)
	}
}

func TestStatusAbsent(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "csc-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	t.Setenv("CS_HOME", dir)
	var out strings.Builder
	code := Status(client.Home{Dir: dir}, &out)
	if code != client.ExitAbsent {
		t.Fatalf("code=%d out=%s", code, out.String())
	}
}

func TestStatusReportsMalformedOwnerMetadata(t *testing.T) {
	dir := t.TempDir()
	home := client.Home{Dir: dir}
	if err := os.WriteFile(home.OwnerPath(), []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}

	var out strings.Builder
	_ = Status(home, &out)
	if !strings.Contains(out.String(), "owner=malformed") {
		t.Fatalf("out=%q", out.String())
	}
}

func TestStop_ForeignPIDIsNeverSignaled(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CS_LAUNCH_AGENTS_DIR", filepath.Join(dir, "LaunchAgents"))
	home := client.Home{Dir: dir}
	cmd := exec.Command("sleep", "30")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
	})
	if err := os.WriteFile(home.PIDPath(), []byte(strconv.Itoa(cmd.Process.Pid)+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	err := Stop(home)
	if err == nil {
		t.Fatal("expected stop to refuse a foreign PID")
	}
	if err := cmd.Process.Signal(syscall.Signal(0)); err != nil {
		t.Fatalf("fixture process was signaled: %v", err)
	}
	if _, statErr := os.Stat(home.PIDPath()); statErr != nil {
		t.Fatal("identity metadata must remain while shutdown is unresolved")
	}
}

func TestRestart_AbortsWhenStopFails(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CS_LAUNCH_AGENTS_DIR", filepath.Join(dir, "LaunchAgents"))
	t.Setenv("CS_HOME", dir)
	t.Setenv("CS_CSD_FORCE_BACKGROUND", "1")
	home := client.Home{Dir: dir}
	if err := os.MkdirAll(home.Dir, 0o700); err != nil {
		t.Fatal(err)
	}
	lock, err := os.OpenFile(home.LockPath(), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { lock.Close() })
	fl := syscall.Flock_t{Type: syscall.F_WRLCK, Whence: 0, Start: 0, Len: 0}
	if err := syscall.FcntlFlock(lock.Fd(), syscall.F_SETLK, &fl); err != nil {
		t.Fatal(err)
	}
	err = Restart(home)
	if err == nil {
		t.Fatal("restart must abort when stop cannot verify the daemon is gone")
	}
}

func TestUsage(t *testing.T) {
	var out, err strings.Builder
	code := Run(nil, &out, &err)
	if code != client.ExitUsage {
		t.Fatalf("code=%d", code)
	}
	if !strings.Contains(out.String(), "csd foreground") {
		t.Fatalf("out=%s", out.String())
	}
}
