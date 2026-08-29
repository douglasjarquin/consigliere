//go:build unix

package client

import (
	"os"
	"path/filepath"
	"testing"
)

func TestProbeLockUnownedAndStale(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "lock")
	state, pid := ProbeLock(path)
	if state != LockUnowned || pid != 0 {
		t.Fatalf("missing lock: %s pid=%d", state, pid)
	}
	if err := os.WriteFile(path, []byte("leftover"), 0o600); err != nil {
		t.Fatal(err)
	}
	state, pid = ProbeLock(path)
	if state != LockStale || pid != 0 {
		t.Fatalf("stale lock: %s pid=%d", state, pid)
	}
}

func TestProbeLockReportsPermissionFailure(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "lock")
	if err := os.WriteFile(path, []byte("private"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o000); err != nil {
		t.Fatal(err)
	}

	state, pid := ProbeLock(path)
	if state != LockPermission || pid != 0 {
		t.Fatalf("permission failure: %s pid=%d", state, pid)
	}
}
