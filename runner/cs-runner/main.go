package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"time"
)

func main() {
	attemptID := flag.String("attempt-id", "", "attempt id")
	missionID := flag.String("mission-id", "", "mission id")
	fencingToken := flag.String("fencing-token", "", "fencing token")
	manifestPath := flag.String("manifest", "", "path to write the runtime manifest")
	controlSocketPath := flag.String("control-socket", "", "path for the control channel unix socket")
	flag.Parse()
	harnessCommand := flag.Args()

	if *attemptID == "" || *manifestPath == "" || *controlSocketPath == "" || len(harnessCommand) == 0 {
		fmt.Fprintln(os.Stderr, "usage: cs-runner --attempt-id ID --manifest PATH --control-socket PATH -- HARNESS_CMD ARGS...")
		os.Exit(2)
	}

	if err := run(*attemptID, *missionID, *fencingToken, *manifestPath, *controlSocketPath, harnessCommand); err != nil {
		fmt.Fprintln(os.Stderr, "cs-runner:", err)
		os.Exit(1)
	}
}

func nowRFC3339() string {
	return time.Now().UTC().Format(time.RFC3339Nano)
}

func run(attemptID, missionID, fencingToken, manifestPath, controlSocketPath string, harnessCommand []string) error {
	base := Manifest{
		SchemaVersion:     1,
		AttemptID:         attemptID,
		MissionID:         missionID,
		FencingToken:      fencingToken,
		ControlSocketPath: controlSocketPath,
		State:             StateStarting,
		StartedAt:         nowRFC3339(),
		LastStateChangeAt: nowRFC3339(),
	}
	if err := WriteManifest(manifestPath, base); err != nil {
		return fmt.Errorf("write starting manifest: %w", err)
	}

	handle, err := SpawnHarness(harnessCommand, 2*time.Second)
	if err != nil {
		return fmt.Errorf("spawn harness: %w", err)
	}

	execPath := harnessCommand[0]
	execHash, _ := sha256File(execPath)

	base.RunnerPID = os.Getpid()
	base.HarnessPID = handle.PID
	base.PGID = handle.PGID
	base.HarnessExecutablePath = execPath
	base.HarnessExecutableSHA256 = execHash
	base.State = StateRunning
	base.LastStateChangeAt = nowRFC3339()
	if err := WriteManifest(manifestPath, base); err != nil {
		return fmt.Errorf("write running manifest: %w", err)
	}

	cc, err := NewControlChannel(controlSocketPath)
	if err != nil {
		return fmt.Errorf("create control channel: %w", err)
	}
	defer cc.Close()

	if err := cc.AcceptOnce(30 * time.Second); err != nil {
		return fmt.Errorf("wait for daemon to connect: %w", err)
	}

	cc.Send(map[string]any{
		"type":                      "runner_started",
		"runner_pid":                base.RunnerPID,
		"harness_pid":               handle.PID,
		"pgid":                      handle.PGID,
		"harness_executable_path":   execPath,
		"harness_executable_sha256": execHash,
		"started_at":                base.StartedAt,
		"attempt_id":                attemptID,
		"mission_id":                missionID,
		"fencing_token":             fencingToken,
	})

	harnessExited := make(chan int, 1)
	go func() {
		waitErr := handle.Cmd.Wait()
		code := 0
		if exitErr, ok := waitErr.(*exec.ExitError); ok {
			code = exitErr.ExitCode()
		}
		harnessExited <- code
	}()

	terminationTriggered := make(chan string, 1)
	go cc.ReadLoop(
		func(msg map[string]any) {
			switch msg["type"] {
			case "cancel":
				select {
				case terminationTriggered <- "cancel":
				default:
				}
			case "ping":
				cc.Send(map[string]any{"type": "pong", "attempt_id": attemptID})
			}
		},
		func() {
			select {
			case terminationTriggered <- "control_eof":
			default:
			}
		},
	)

	select {
	case code := <-harnessExited:
		cc.Send(map[string]any{"type": "harness_exited", "attempt_id": attemptID, "exit_code": code, "signaled": false})
		deadAt := nowRFC3339()
		final := base
		final.State = StateDeadVerified
		final.ExitCode = &code
		final.VerifiedDeadAt = &deadAt
		final.LastStateChangeAt = deadAt
		return WriteManifest(manifestPath, final)

	case reason := <-terminationTriggered:
		terminating := base
		terminating.State = StateTerminating
		terminating.LastStateChangeAt = nowRFC3339()
		if err := WriteManifest(manifestPath, terminating); err != nil {
			return fmt.Errorf("write terminating manifest: %w", err)
		}

		verified, _ := Terminate(handle.PGID, 5*time.Second, 2*time.Second)

		deadAt := nowRFC3339()
		final := base
		final.LastStateChangeAt = deadAt
		reasonCopy := reason
		final.TerminationReason = &reasonCopy
		if verified {
			final.State = StateDeadVerified
			final.VerifiedDeadAt = &deadAt
		} else {
			final.State = StateDeadUnverified
		}
		if err := WriteManifest(manifestPath, final); err != nil {
			return fmt.Errorf("write final manifest: %w", err)
		}

		cc.Send(map[string]any{
			"type":               "termination_complete",
			"attempt_id":         attemptID,
			"verified_dead":      verified,
			"termination_reason": reason,
		})

		return nil
	}
}
