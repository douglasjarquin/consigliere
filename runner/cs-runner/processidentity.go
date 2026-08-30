package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"time"
)

const processIdentityTimeout = 2 * time.Second

var errProcessNotFound = errors.New("process not found")

func processStartFingerprint(pid int) (string, error) {
	if pid <= 1 {
		return "", fmt.Errorf("process PID must be non-degenerate")
	}

	switch runtime.GOOS {
	case "linux":
		return linuxProcessStartFingerprint(pid)
	case "darwin":
		return psProcessStartFingerprint(pid)
	default:
		return psProcessStartFingerprint(pid)
	}
}

func linuxProcessStartFingerprint(pid int) (string, error) {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		if os.IsNotExist(err) {
			return "", errProcessNotFound
		}
		return "", err
	}

	closing := strings.LastIndex(string(data), ") ")
	if closing < 0 {
		return "", fmt.Errorf("process stat has no command terminator")
	}
	fields := strings.Fields(string(data[closing+2:]))
	if len(fields) <= 19 || fields[19] == "" {
		return "", fmt.Errorf("process stat has no start time")
	}

	return "linux:" + fields[19], nil
}

func psProcessStartFingerprint(pid int) (string, error) {
	paths := []string{"/bin/ps", "/usr/bin/ps"}
	var lastErr error

	for _, path := range paths {
		if _, err := os.Stat(path); err != nil {
			lastErr = err
			continue
		}

		ctx, cancel := context.WithTimeout(context.Background(), processIdentityTimeout)
		output, err := exec.CommandContext(ctx, path, "-o", "lstart=", "-p", strconv.Itoa(pid)).CombinedOutput()
		cancel()
		if err == nil {
			value := strings.TrimSpace(string(output))
			if value != "" {
				return "ps:" + value, nil
			}
			return "", fmt.Errorf("process start time is empty")
		}
		if exitErr, ok := err.(*exec.ExitError); ok &&
			(strings.TrimSpace(string(exitErr.Stderr)) == "" || strings.Contains(strings.ToLower(string(output)), "no such process")) {
			return "", errProcessNotFound
		}
		lastErr = err
	}

	return "", lastErr
}
