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
	return runWithAcceptTimeout(attemptID, missionID, fencingToken, manifestPath, controlSocketPath, harnessCommand, 30*time.Second)
}

// terminateAndFinalize runs the termination sequence against base's process
// group and writes the resulting terminal manifest state (dead_verified or
// dead_unverified), shared by every path that ends a runner's life: a
// natural harness exit (which may still leave stragglers in the group), an
// explicit termination trigger, and a post-spawn failure that must not
// abandon an already-running harness.
func terminateAndFinalize(manifestPath string, base Manifest, exitCode *int, reason *string) (verified bool, err error) {
	verified, _ = Terminate(base.PGID, 5*time.Second, 2*time.Second)

	deadAt := nowRFC3339()
	final := base
	final.ExitCode = exitCode
	final.TerminationReason = reason
	final.LastStateChangeAt = deadAt
	if verified {
		final.State = StateDeadVerified
		final.VerifiedDeadAt = &deadAt
	} else {
		final.State = StateDeadUnverified
	}
	return verified, WriteManifest(manifestPath, final)
}

func runWithAcceptTimeout(attemptID, missionID, fencingToken, manifestPath, controlSocketPath string, harnessCommand []string, acceptTimeout time.Duration) error {
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

	// Start reaping the harness the moment it is spawned, not after control-
	// channel setup: a later Terminate call's own process-group verification
	// depends on the harness being promptly reaped by its actual parent (this
	// process), since an unreaped zombie leader makes kill(-pgid, 0) return
	// EPERM rather than ESRCH on at least one real platform this was tested
	// against, which would otherwise be misread as "cannot verify" for a
	// harness that is, in fact, already dead.
	harnessExited := make(chan int, 1)
	go func() {
		waitErr := handle.Cmd.Wait()
		code := 0
		if exitErr, ok := waitErr.(*exec.ExitError); ok {
			code = exitErr.ExitCode()
		}
		harnessExited <- code
	}()

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
		reason := "control_channel_setup_failed"
		terminateAndFinalize(manifestPath, base, nil, &reason)
		return fmt.Errorf("create control channel: %w", err)
	}
	defer cc.Close()

	if err := cc.AcceptOnce(acceptTimeout); err != nil {
		reason := "daemon_never_connected"
		terminateAndFinalize(manifestPath, base, nil, &reason)
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

		// The harness itself exiting does not mean its process group is
		// empty: it may have backgrounded a child before exiting, still
		// alive under the same pgid. terminateAndFinalize reaps any such
		// stragglers before trusting Wait() as proof the group is clear.
		_, err := terminateAndFinalize(manifestPath, base, &code, nil)
		return err

	case reason := <-terminationTriggered:
		terminating := base
		terminating.State = StateTerminating
		terminating.LastStateChangeAt = nowRFC3339()
		if err := WriteManifest(manifestPath, terminating); err != nil {
			return fmt.Errorf("write terminating manifest: %w", err)
		}

		reasonCopy := reason
		verified, err := terminateAndFinalize(manifestPath, base, nil, &reasonCopy)
		if err != nil {
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
