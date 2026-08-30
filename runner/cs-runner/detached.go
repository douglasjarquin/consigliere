package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"syscall"
)

func startDetachedRunner(executable string, args []string, bootstrap Bootstrap) (*exec.Cmd, error) {
	if executable == "" {
		return nil, fmt.Errorf("runner executable must not be empty")
	}
	if _, err := bootstrap.secret(); err != nil {
		return nil, err
	}
	bootstrapData, err := json.Marshal(bootstrap)
	if err != nil {
		return nil, fmt.Errorf("encode private runner bootstrap: %w", err)
	}

	cmd := exec.Command(executable, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	cmd.Env = append(os.Environ(), "CS_RUNNER_DETACHED=1")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("open detached runner bootstrap: %w", err)
	}
	if err := cmd.Start(); err != nil {
		_ = stdin.Close()
		return nil, fmt.Errorf("start detached runner: %w", err)
	}

	if _, err := stdin.Write(append(bootstrapData, '\n')); err != nil {
		_ = stdin.Close()
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return nil, fmt.Errorf("send detached runner bootstrap: %w", err)
	}
	if err := stdin.Close(); err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return nil, fmt.Errorf("close detached runner bootstrap: %w", err)
	}
	return cmd, nil
}
