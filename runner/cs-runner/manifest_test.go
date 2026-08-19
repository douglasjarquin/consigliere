package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func testManifest(attemptID string) Manifest {
	return Manifest{
		SchemaVersion:         1,
		AttemptID:             attemptID,
		MissionID:             "mission-1",
		FencingToken:          "fence-1",
		RunnerPID:             1234,
		HarnessPID:            1235,
		PGID:                  1234,
		HarnessExecutablePath: "/bin/true",
		StartedAt:             time.Now().UTC().Format(time.RFC3339Nano),
		ControlSocketPath:     "/tmp/control.sock",
		State:                 StateStarting,
		LastStateChangeAt:     time.Now().UTC().Format(time.RFC3339Nano),
	}
}

func TestWriteManifest_RoundTrips(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "manifest.json")
	m := testManifest("attempt-1")

	if err := WriteManifest(path, m); err != nil {
		t.Fatalf("WriteManifest: %v", err)
	}

	got, err := ReadManifest(path)
	if err != nil {
		t.Fatalf("ReadManifest: %v", err)
	}
	if got.AttemptID != m.AttemptID || got.State != m.State || got.PGID != m.PGID {
		t.Fatalf("round-trip mismatch: got %+v, want %+v", got, m)
	}
}

func TestWriteManifest_NoTempFilesLeftBehind(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "manifest.json")
	m := testManifest("attempt-1")

	for i := 0; i < 5; i++ {
		if err := WriteManifest(path, m); err != nil {
			t.Fatalf("WriteManifest: %v", err)
		}
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected exactly 1 file in manifest dir (no leftover temp files), got %d: %v", len(entries), entries)
	}
}

// A concurrent reader must never observe a partially written manifest: every
// read either fails because the file does not exist yet, or succeeds with
// fully valid JSON. It must never see a truncated/partial write, which is
// exactly what the temp-file-then-rename sequence exists to prevent.
func TestWriteManifest_ConcurrentReadersNeverSeePartialWrites(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "manifest.json")

	var partialReads int64
	var wg sync.WaitGroup
	stop := make(chan struct{})

	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				data, err := os.ReadFile(path)
				if err != nil {
					continue
				}
				var m Manifest
				if jsonErr := json.Unmarshal(data, &m); jsonErr != nil {
					atomic.AddInt64(&partialReads, 1)
				}
			}
		}()
	}

	for i := 0; i < 500; i++ {
		m := testManifest("attempt-1")
		m.State = ManifestState([]byte{byte('a' + i%26)})
		if err := WriteManifest(path, m); err != nil {
			t.Fatalf("WriteManifest: %v", err)
		}
	}

	close(stop)
	wg.Wait()

	if partialReads != 0 {
		t.Fatalf("readers observed %d partial/invalid manifest reads", partialReads)
	}
}
