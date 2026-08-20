package service

import (
	"os"
	"path/filepath"
	"strings"
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
