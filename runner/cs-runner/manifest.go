package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

type ManifestState string

const (
	StateStarting       ManifestState = "starting"
	StateRunning        ManifestState = "running"
	StateTerminating    ManifestState = "terminating"
	StateDeadVerified   ManifestState = "dead_verified"
	StateDeadUnverified ManifestState = "dead_unverified"
)

type Manifest struct {
	SchemaVersion           int           `json:"schema_version"`
	ProtocolVersion         int           `json:"protocol_version"`
	InvocationID            string        `json:"invocation_id"`
	AttemptID               string        `json:"attempt_id"`
	MissionID               string        `json:"mission_id"`
	WorkspacePath           string        `json:"workspace_path"`
	WorkspaceGeneration     string        `json:"workspace_generation"`
	FencingGeneration       string        `json:"fencing_generation"`
	FencingToken            string        `json:"fencing_token"`
	RunnerPID               int           `json:"runner_pid"`
	HarnessPID              int           `json:"harness_pid"`
	PGID                    int           `json:"pgid"`
	HarnessExecutablePath   string        `json:"harness_executable_path"`
	HarnessExecutableSHA256 string        `json:"harness_executable_sha256"`
	RunnerExecutableSHA256  string        `json:"runner_executable_sha256"`
	StartedAt               string        `json:"started_at"`
	ControlSocketPath       string        `json:"control_socket_path"`
	State                   ManifestState `json:"state"`
	LastStateChangeAt       string        `json:"last_state_change_at"`
	ExitCode                *int          `json:"exit_code"`
	TerminationReason       *string       `json:"termination_reason"`
	VerifiedDeadAt          *string       `json:"verified_dead_at"`
}

// WriteManifest implements docs/protocols/runner.md's crash-safe write
// sequence: temp file in the same directory, fsync the file, atomic rename,
// then fsync the containing directory so the rename itself survives a host
// crash, not just becomes visible to other processes. A reader must never
// observe a partially written manifest.
func WriteManifest(path string, m Manifest) error {
	data, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal manifest: %w", err)
	}

	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, "manifest.json.tmp-*")
	if err != nil {
		return fmt.Errorf("create temp manifest: %w", err)
	}
	tmpPath := tmp.Name()

	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return fmt.Errorf("write temp manifest: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return fmt.Errorf("fsync temp manifest: %w", err)
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("close temp manifest: %w", err)
	}

	if err := os.Rename(tmpPath, path); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("rename manifest into place: %w", err)
	}

	dirFile, err := os.Open(dir)
	if err != nil {
		return fmt.Errorf("open manifest directory for fsync: %w", err)
	}
	defer dirFile.Close()
	if err := dirFile.Sync(); err != nil {
		return fmt.Errorf("fsync manifest directory: %w", err)
	}

	return nil
}

func ReadManifest(path string) (Manifest, error) {
	var m Manifest
	data, err := os.ReadFile(path)
	if err != nil {
		return m, err
	}
	if err := json.Unmarshal(data, &m); err != nil {
		return m, fmt.Errorf("unmarshal manifest: %w", err)
	}
	return m, nil
}
