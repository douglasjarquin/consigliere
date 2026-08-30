package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"syscall"
)

func startDetachedRunner(executable string, args []string, bootstrap Bootstrap) error {
	if executable == "" {
		return fmt.Errorf("runner executable must not be empty")
	}
	if _, err := bootstrap.secret(); err != nil {
		return err
	}
	bootstrapData, err := json.Marshal(bootstrap)
	if err != nil {
		return fmt.Errorf("encode private runner bootstrap: %w", err)
	}

	cmd := exec.Command(executable, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	cmd.Env = append(os.Environ(), "CS_RUNNER_DETACHED=1")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return fmt.Errorf("open detached runner bootstrap: %w", err)
	}
	if err := cmd.Start(); err != nil {
		_ = stdin.Close()
		return fmt.Errorf("start detached runner: %w", err)
	}

	if _, err := stdin.Write(append(bootstrapData, '\n')); err != nil {
		_ = stdin.Close()
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return fmt.Errorf("send detached runner bootstrap: %w", err)
	}
	if err := stdin.Close(); err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return fmt.Errorf("close detached runner bootstrap: %w", err)
	}
	return nil
}
