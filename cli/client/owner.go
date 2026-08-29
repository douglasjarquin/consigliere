package client

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"syscall"
)

type OwnerState string

const (
	OwnerAbsent     OwnerState = "absent"
	OwnerVerified   OwnerState = "verified"
	OwnerStale      OwnerState = "stale"
	OwnerMalformed  OwnerState = "malformed"
	OwnerPermission OwnerState = "permission"
)

type ownerRecord struct {
	Pid  int    `json:"pid"`
	Home string `json:"home"`
}

func ProbeOwner(path string) (OwnerState, string) {
	b, err := os.ReadFile(path)
	if err != nil {
		switch {
		case errors.Is(err, fs.ErrNotExist):
			return OwnerAbsent, ""
		case errors.Is(err, fs.ErrPermission):
			return OwnerPermission, "owner metadata is unreadable"
		default:
			return OwnerMalformed, "owner metadata cannot be read"
		}
	}

	var owner ownerRecord
	if err := json.Unmarshal(b, &owner); err != nil {
		return OwnerMalformed, "owner metadata is not valid JSON"
	}
	if owner.Pid <= 1 {
		return OwnerMalformed, "owner metadata has no process identity"
	}

	process, err := os.FindProcess(owner.Pid)
	if err != nil || process.Signal(syscall.Signal(0)) != nil {
		return OwnerStale, fmt.Sprintf("owner process %d is not live", owner.Pid)
	}
	return OwnerVerified, ""
}
