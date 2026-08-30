package main

import (
	"encoding/hex"
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
	workspacePath := flag.String("workspace-path", "", "trusted workspace path")
	workspaceGeneration := flag.String("workspace-generation", "", "trusted workspace generation")
	fencingGeneration := flag.String("fencing-generation", "", "trusted fencing generation")
	invocationID := flag.String("invocation-id", "", "unique runner invocation id")
	manifestPath := flag.String("manifest", "", "path to write the runtime manifest")
	controlSocketPath := flag.String("control-socket", "", "path for the control channel unix socket")
	flag.Parse()
	harnessCommand := flag.Args()

	identity := InvocationIdentity{
		ProtocolVersion:     controlProtocolVersion,
		InvocationID:        *invocationID,
		AttemptID:           *attemptID,
		MissionID:           *missionID,
		WorkspacePath:       *workspacePath,
		WorkspaceGeneration: *workspaceGeneration,
		FencingGeneration:   *fencingGeneration,
	}
	if identity.validate() != nil || *manifestPath == "" || *controlSocketPath == "" || len(harnessCommand) == 0 {
		fmt.Fprintln(os.Stderr, "usage: cs-runner --attempt-id ID --mission-id ID --workspace-path PATH --workspace-generation ID --fencing-generation ID --invocation-id ID --manifest PATH --control-socket PATH -- HARNESS_CMD ARGS...")
		os.Exit(2)
	}

	bootstrap, err := readBootstrapFromStdin()
	if err != nil {
		fmt.Fprintln(os.Stderr, "cs-runner:", err)
		os.Exit(2)
	}
	if err := validateBootstrapIdentity(bootstrap, identity); err != nil {
		fmt.Fprintln(os.Stderr, "cs-runner:", err)
		os.Exit(2)
	}
	bootstrap.CloseStdin = true
	defer os.Stdin.Close()

	if err := runAuthenticated(identity, *manifestPath, *controlSocketPath, bootstrap, harnessCommand, 30*time.Second); err != nil {
		fmt.Fprintln(os.Stderr, "cs-runner:", err)
		os.Exit(1)
	}
}

func nowRFC3339() string {
	return time.Now().UTC().Format(time.RFC3339Nano)
}

func run(attemptID, missionID, fencingToken, manifestPath, controlSocketPath string, harnessCommand []string) error {
	identity := InvocationIdentity{
		ProtocolVersion:     controlProtocolVersion,
		InvocationID:        "test-invocation-" + attemptID,
		AttemptID:           attemptID,
		MissionID:           missionID,
		WorkspacePath:       "test-workspace",
		WorkspaceGeneration: "test-workspace-generation",
		FencingGeneration:   fencingToken,
	}
	bootstrap := Bootstrap{
		SecretHex: hex.EncodeToString([]byte("01234567890123456789012345678901")),
		Identity:  identity,
	}
	return runAuthenticated(identity, manifestPath, controlSocketPath, bootstrap, harnessCommand, 30*time.Second)
}

func runWithAcceptTimeout(attemptID, missionID, fencingToken, manifestPath, controlSocketPath string, harnessCommand []string, acceptTimeout time.Duration) error {
	identity := InvocationIdentity{
		ProtocolVersion:     controlProtocolVersion,
		InvocationID:        "test-invocation-" + attemptID,
		AttemptID:           attemptID,
		MissionID:           missionID,
		WorkspacePath:       "test-workspace",
		WorkspaceGeneration: "test-workspace-generation",
		FencingGeneration:   fencingToken,
	}
	bootstrap := Bootstrap{
		SecretHex: hex.EncodeToString([]byte("01234567890123456789012345678901")),
		Identity:  identity,
	}
	return runAuthenticated(identity, manifestPath, controlSocketPath, bootstrap, harnessCommand, acceptTimeout)
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
	return verified, finalizeManifest(manifestPath, base, verified, exitCode, reason)
}

func finalizeManifest(manifestPath string, base Manifest, verified bool, exitCode *int, reason *string) error {
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
	return writeManifestFn(manifestPath, final)
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

func runAuthenticated(identity InvocationIdentity, manifestPath, controlSocketPath string, bootstrap Bootstrap, harnessCommand []string, acceptTimeout time.Duration) error {
	base := Manifest{
		SchemaVersion:       1,
		ProtocolVersion:     identity.ProtocolVersion,
		InvocationID:        identity.InvocationID,
		AttemptID:           identity.AttemptID,
		MissionID:           identity.MissionID,
		WorkspacePath:       identity.WorkspacePath,
		WorkspaceGeneration: identity.WorkspaceGeneration,
		FencingGeneration:   identity.FencingGeneration,
		FencingToken:        identity.FencingGeneration,
		ControlSocketPath:   controlSocketPath,
		State:               StateStarting,
		StartedAt:           nowRFC3339(),
		LastStateChangeAt:   nowRFC3339(),
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
	forwarder := startStreamForwarder(handle.Stdout, handle.Stderr, identity.AttemptID, identity.FencingGeneration)

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
	runnerPath, _ := os.Executable()
	runnerHash, _ := sha256File(runnerPath)

	base.RunnerPID = os.Getpid()
	base.RunnerExecutablePath, _ = os.Executable()
	base.HarnessPID = handle.PID
	base.PGID = handle.PGID
	base.HarnessExecutablePath = execPath
	base.HarnessExecutableSHA256 = execHash
	base.RunnerExecutableSHA256 = runnerHash
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

	manifestDigest, err := manifestFileDigest(manifestPath)
	if err != nil {
		terminateAndReport(manifestPath, base, descendants, "manifest_digest_failed")
		return fmt.Errorf("hash running manifest: %w", err)
	}
	runnerIdentity := RunnerIdentity{
		InvocationIdentity:      identity,
		RunnerPID:               base.RunnerPID,
		PGID:                    base.PGID,
		ManifestDigest:          manifestDigest,
		RunnerExecutableSHA256:  base.RunnerExecutableSHA256,
		HarnessExecutableSHA256: base.HarnessExecutableSHA256,
	}
	if err := cc.AcceptHandshake(bootstrap, runnerIdentity, acceptTimeout); err != nil {
		terminateAndReport(manifestPath, base, descendants, "daemon_never_connected")
		return fmt.Errorf("wait for daemon to connect: %w", err)
	}
	if bootstrap.CloseStdin {
		_ = os.Stdin.Close()
	}

	_ = cc.SendFrame(map[string]any{
		"type":                      "runner_started",
		"runner_pid":                base.RunnerPID,
		"harness_pid":               handle.PID,
		"pgid":                      handle.PGID,
		"harness_executable_path":   execPath,
		"harness_executable_sha256": execHash,
		"started_at":                base.StartedAt,
		"attempt_id":                identity.AttemptID,
		"mission_id":                identity.MissionID,
		"fencing_token":             identity.FencingGeneration,
		"invocation_id":             identity.InvocationID,
		"workspace_path":            identity.WorkspacePath,
		"workspace_generation":      identity.WorkspaceGeneration,
		"fencing_generation":        identity.FencingGeneration,
		"manifest_digest":           manifestDigest,
		"runner_executable_sha256":  base.RunnerExecutableSHA256,
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
				_ = cc.SendFrame(map[string]any{"type": "pong", "attempt_id": identity.AttemptID})
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
		// The harness itself exiting does not mean its process group is
		// empty: it may have backgrounded a child before exiting, still
		// alive under the same pgid. terminateAndFinalize reaps any such
		// stragglers before trusting Wait() as proof the group is clear.
		code := result.code
		verified, _ := TerminateGroupAndDescendants(base.PGID, descendants, 5*time.Second, 2*time.Second)
		if !verified {
			_ = cc.Close()
			forwarder.CloseInputs()
			_ = forwarder.Wait(streamWriteTimeout)
			reason := "termination_unverified"
			return finalizeManifest(manifestPath, base, false, &code, &reason)
		}
		if err := forwarder.Wait(streamDrainTimeout); err != nil {
			_ = cc.Close()
			forwarder.CloseInputs()
			_ = forwarder.Wait(streamWriteTimeout)
			failedCode := -1
			reason := "stream_delivery_failed"
			finalizeErr := finalizeManifest(manifestPath, base, verified, &failedCode, &reason)
			if finalizeErr != nil {
				return fmt.Errorf("stream delivery failed: %v; write final manifest: %w", err, finalizeErr)
			}
			return fmt.Errorf("stream delivery failed: %w", err)
		}
		if err := cc.SendFrame(map[string]any{
			"type":       "harness_exited",
			"attempt_id": identity.AttemptID,
			"exit_code":  result.code,
			"signaled":   result.signaled,
		}); err != nil {
			_ = cc.Close()
			failedCode := -1
			reason := "harness_exit_delivery_failed"
			finalizeErr := finalizeManifest(manifestPath, base, verified, &failedCode, &reason)
			if finalizeErr != nil {
				return fmt.Errorf("harness exit delivery failed: %v; write final manifest: %w", err, finalizeErr)
			}
			return fmt.Errorf("harness exit delivery failed: %w", err)
		}
		err := finalizeManifest(manifestPath, base, verified, &code, nil)
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
			_ = cc.Close()
			forwarder.CloseInputs()
			return fmt.Errorf("write final manifest: %w", err)
		}
		if !verified {
			_ = cc.Close()
			forwarder.CloseInputs()
			_ = forwarder.Wait(streamWriteTimeout)
			return nil
		}
		if err := forwarder.Wait(streamDrainTimeout); err != nil {
			_ = cc.Close()
			forwarder.CloseInputs()
			_ = forwarder.Wait(streamWriteTimeout)
			if reason == "control_eof" {
				return nil
			}
			return fmt.Errorf("stream delivery failed during %s: %w", reason, err)
		}

		if err := cc.SendFrame(map[string]any{
			"type":               "termination_complete",
			"attempt_id":         identity.AttemptID,
			"verified_dead":      verified,
			"termination_reason": reason,
		}); err != nil {
			_ = cc.Close()
			if reason == "control_eof" {
				return nil
			}
			return fmt.Errorf("termination completion delivery failed: %w", err)
		}

		return nil
	}
}
