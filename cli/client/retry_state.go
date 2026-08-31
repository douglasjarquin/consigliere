package client

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

type retryState struct {
	Operation string         `json:"operation"`
	Scope     string         `json:"scope"`
	Key       string         `json:"idempotency_key"`
	Hash      string         `json:"canonical_hash"`
	Payload   map[string]any `json:"payload"`
}

func (h Home) retryStateDir() string {
	return filepath.Join(h.Dir, "requests")
}

func (h Home) findRetryState(op, scope string, version int, payload map[string]any) (retryState, bool, error) {
	entries, err := os.ReadDir(h.retryStateDir())
	if errors.Is(err, os.ErrNotExist) {
		return retryState{}, false, nil
	}
	if err != nil {
		return retryState{}, false, fmt.Errorf("read retry state: %w", err)
	}

	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		data, readErr := os.ReadFile(filepath.Join(h.retryStateDir(), entry.Name()))
		if readErr != nil || len(data) > 1<<20 {
			continue
		}
		var state retryState
		if json.Unmarshal(data, &state) != nil || state.Operation != op || state.Scope != scope {
			continue
		}
		currentHash, currentErr := CanonicalRequestHash(scope, op, version, state.Key, payload)
		if currentErr == nil && currentHash == state.Hash {
			return state, true, nil
		}
	}

	return retryState{}, false, nil
}

func (h Home) saveRetryState(state retryState) error {
	dir := h.retryStateDir()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create retry state directory: %w", err)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return fmt.Errorf("protect retry state directory: %w", err)
	}
	data, err := json.Marshal(state)
	if err != nil {
		return fmt.Errorf("encode retry state: %w", err)
	}
	temporary, err := os.CreateTemp(dir, ".pending-*.tmp")
	if err != nil {
		return fmt.Errorf("create retry state: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return fmt.Errorf("protect retry state: %w", err)
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return fmt.Errorf("write retry state: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return fmt.Errorf("sync retry state: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close retry state: %w", err)
	}
	if err := os.Rename(temporaryPath, filepath.Join(dir, state.Hash+".json")); err != nil {
		return fmt.Errorf("commit retry state: %w", err)
	}
	return nil
}

func (h Home) removeRetryState(state retryState) error {
	err := os.Remove(filepath.Join(h.retryStateDir(), state.Hash+".json"))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("remove retry state: %w", err)
	}
	return nil
}
