package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSHA256File_MatchesKnownContent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "sample")
	if err := os.WriteFile(path, []byte("hello\n"), 0o644); err != nil {
		t.Fatalf("write sample file: %v", err)
	}

	got, err := sha256File(path)
	if err != nil {
		t.Fatalf("sha256File: %v", err)
	}

	want := "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
	if got != want {
		t.Fatalf("sha256File(%q) = %q, want %q", path, got, want)
	}
}

func TestSHA256File_ReturnsErrorForMissingFile(t *testing.T) {
	_, err := sha256File("/no/such/file-cs-runner-test")
	if err == nil {
		t.Fatalf("expected an error for a missing file")
	}
}
