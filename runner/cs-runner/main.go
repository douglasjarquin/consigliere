package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"syscall"
	"time"
)

// writeManifestFn is a package-level seam so tests can simulate a manifest
// write failure at a specific point in the runner's lifecycle without
// depending on a real, precisely-timed disk/permissions fault.
var writeManifestFn = WriteManifest

// descendantPollInterval bounds how quickly startDescendantTracker can
// observe a new descendant of the harness -- short enough to catch a
// harness that spawns an escaping grandchild and exits almost immediately.
// Polling this often has a real, measured `ps`-subprocess cost (see
// docs/spikes/spike-c-results.md's Known Limitations); this value is not
// tuned against that cost, only against the escape-detection window.
const descendantPollInterval = 150 * time.Millisecond

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
// abandon an already-running harness. tracker is stopped as part of this
// call (see TerminateGroupAndDescendants) and must not be reused afterward.
func terminateAndFinalize(manifestPath string, base Manifest, tracker *descendantTracker, exitCode *int, reason *string) (verified bool, err error) {
	verified, _ = TerminateGroupAndDescendants(base.PGID, tracker, 5*time.Second, 2*time.Second)

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
	return verified, writeManifestFn(manifestPath, final)
}

// terminateAndReport runs terminateAndFinalize and, if the final manifest
// write itself fails, reports that to stderr instead of discarding it: a
// silently-abandoned write failure here would leave an on-disk manifest that
// falsely still claims "running" for a process group that has, in fact,
// already been terminated.
func terminateAndReport(manifestPath string, base Manifest, tracker *descendantTracker, reason string) {
	reasonCopy := reason
	if _, err := terminateAndFinalize(manifestPath, base, tracker, nil, &reasonCopy); err != nil {
		fmt.Fprintf(os.Stderr, "cs-runner: terminated harness (%s) but failed to write the final manifest: %v\n", reason, err)
	}
}

type harnessExitResult struct {
	code     int
	signaled bool
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
	if err := writeManifestFn(manifestPath, base); err != nil {
		return fmt.Errorf("write starting manifest: %w", err)
	}

	handle, err := SpawnHarness(harnessCommand, 2*time.Second)
	if err != nil {
		return fmt.Errorf("spawn harness: %w", err)
	}

	// Drain stdio immediately so the harness cannot block on a full pipe
	// while we set up the control channel. Attach happens only after
	// runner_started, so launch() always sees that message first.
	forwarder := startStreamForwarder(handle.Stdout, handle.Stderr, attemptID, fencingToken)

	// Start reaping the harness the moment it is spawned, not after control-
	// channel setup: a later Terminate call's own process-group verification
	// depends on the harness being promptly reaped by its actual parent (this
	// process), since an unreaped zombie leader makes kill(-pgid, 0) return
	// EPERM rather than ESRCH on at least one real platform this was tested
	// against, which would otherwise be misread as "cannot verify" for a
	// harness that is, in fact, already dead. This must never be delayed
	// waiting on descendant tracking's own first `ps` call below: a
	// verification-gate round found that starting the tracker here instead
	// left an already-spawned harness with no reaper and no persisted pgid
	// whenever that first `ps` call was slow or hung.
	harnessExited := make(chan harnessExitResult, 1)
	go func() {
		waitErr := handle.Cmd.Wait()
		var result harnessExitResult
		if exitErr, ok := waitErr.(*exec.ExitError); ok {
			if status, ok := exitErr.Sys().(syscall.WaitStatus); ok {
				result.signaled = status.Signaled()
				if result.signaled {
					result.code = -1
				} else {
					result.code = status.ExitStatus()
				}
			} else {
				result.code = exitErr.ExitCode()
			}
		}
		harnessExited <- result
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
	if err := writeManifestFn(manifestPath, base); err != nil {
		// The harness is already spawned and already being reaped, but
		// descendant tracking has not started yet: start it now, right
		// before best-effort cleanup, rather than leaving an escapee that
		// exists by this point completely untracked.
		terminateAndReport(manifestPath, base, startDescendantTracker(handle.PID, descendantPollInterval), "running_manifest_write_failed")
		return fmt.Errorf("write running manifest: %w", err)
	}

	// Start tracking the harness's OS-process-tree descendants only once
	// it is durably recorded as running and its own reaper is already in
	// place, never before: a descendant that calls setsid() itself
	// escapes the harness's own process group (which a group-scoped
	// kill(-pgid, ...) can never reach), and by the time termination
	// begins the harness may already be dead and any escaped descendant
	// already reparented to init, severing the parent-child link a
	// snapshot taken only at termination time would need -- but this
	// tracking's own first `ps` call must never be allowed to delay the
	// reaper or the manifest write above it depends on.
	descendants := startDescendantTracker(handle.PID, descendantPollInterval)

	cc, err := NewControlChannel(controlSocketPath)
	if err != nil {
		terminateAndReport(manifestPath, base, descendants, "control_channel_setup_failed")
		return fmt.Errorf("create control channel: %w", err)
	}
	defer cc.Close()

	if err := cc.AcceptOnce(acceptTimeout); err != nil {
		terminateAndReport(manifestPath, base, descendants, "daemon_never_connected")
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
	forwarder.Attach(cc)

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
	case result := <-harnessExited:
		cc.Send(map[string]any{
			"type":       "harness_exited",
			"attempt_id": attemptID,
			"exit_code":  result.code,
			"signaled":   result.signaled,
		})

		// The harness itself exiting does not mean its process group is
		// empty: it may have backgrounded a child before exiting, still
		// alive under the same pgid. terminateAndFinalize reaps any such
		// stragglers before trusting Wait() as proof the group is clear.
		code := result.code
		_, err := terminateAndFinalize(manifestPath, base, descendants, &code, nil)
		return err

	case reason := <-terminationTriggered:
		terminating := base
		terminating.State = StateTerminating
		terminating.LastStateChangeAt = nowRFC3339()
		if err := writeManifestFn(manifestPath, terminating); err != nil {
			terminateAndReport(manifestPath, base, descendants, reason)
			return fmt.Errorf("write terminating manifest: %w", err)
		}

		reasonCopy := reason
		verified, err := terminateAndFinalize(manifestPath, base, descendants, nil, &reasonCopy)
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
