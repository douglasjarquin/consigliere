package service

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/douglasjarquin/consigliere/cli/client"
)

const (
	shutdownGrace = 30 * time.Second
	termGrace     = 5 * time.Second
	killGrace     = 2 * time.Second
)

func Restart(home client.Home) error {
	target, err := normalizeHome(home)
	if err != nil {
		return fmt.Errorf("restart target: %w", err)
	}
	if err := Stop(target); err != nil {
		return err
	}
	return Start(target)
}

func Stop(home client.Home) error {
	target, err := normalizeHome(home)
	if err != nil {
		return fmt.Errorf("stop target: %w", err)
	}
	home = target

	owner, identErr := verifiedOwner(home)
	if identErr != nil {
		if _, statErr := os.Lstat(home.OwnerPath()); statErr == nil {
			return fmt.Errorf("refusing to control an unverified owner: %w", identErr)
		} else if !errors.Is(statErr, fs.ErrNotExist) {
			return fmt.Errorf("cannot inspect owner metadata: %w", statErr)
		}
		return stopWithoutOwner(home)
	}

	shutdownErr := requestShutdown(home)
	if shutdownErr != nil {
		switch {
		case errors.Is(shutdownErr, client.ErrUnauthorized), errors.Is(shutdownErr, client.ErrProtocol),
			errors.Is(shutdownErr, fs.ErrNotExist):
			return fmt.Errorf("authenticated shutdown request failed: %w", shutdownErr)
		}
	}
	if err := stopLaunchAgent(home); err != nil {
		return err
	}

	if err := waitForStopped(home, owner, shutdownGrace); err == nil {
		return cleanupStopped(home, owner)
	}

	owner, err = verifiedOwner(home)
	if err != nil {
		return fmt.Errorf("stop incomplete before SIGTERM: %w", err)
	}
	if err := signalVerifiedGroup(home, owner, syscall.SIGTERM); err != nil {
		return err
	}
	if err := waitForStopped(home, owner, termGrace); err == nil {
		return cleanupStopped(home, owner)
	}

	owner, err = verifiedOwner(home)
	if err != nil {
		return fmt.Errorf("stop incomplete before SIGKILL: %w", err)
	}
	if err := signalVerifiedGroup(home, owner, syscall.SIGKILL); err != nil {
		return err
	}
	if err := waitForStopped(home, owner, killGrace); err != nil {
		return fmt.Errorf("stop incomplete: %w", err)
	}
	return cleanupStopped(home, owner)
}

func requestShutdown(home client.Home) error {
	secret, err := home.BossSecret()
	if err != nil {
		return fmt.Errorf("boss credential: %w", err)
	}
	if secret == "" {
		return errors.New("boss credential is empty")
	}
	d := client.NewBossDialer(home)
	d.Secret = secret
	d.ReadTimeout = 2 * time.Second
	response, err := d.Call("daemon.shutdown", nil, "", "")
	if err != nil {
		return err
	}
	if response == nil || !response.OK {
		return errors.New("daemon rejected shutdown request")
	}
	return nil
}

func stopLaunchAgent(home client.Home) error {
	if runtime.GOOS != "darwin" {
		return nil
	}
	plist := PlistPathFor(home)
	if _, err := os.Stat(plist); errors.Is(err, fs.ErrNotExist) {
		return nil
	} else if err != nil {
		return fmt.Errorf("cannot inspect launch agent: %w", err)
	}
	if err := launchctl("bootout", "gui/"+strconv.Itoa(os.Getuid())+"/"+labelForHome(home)); err != nil {
		if strings.Contains(err.Error(), "Could not find service") || strings.Contains(err.Error(), "No such process") {
			return nil
		}
		return fmt.Errorf("launch agent shutdown failed: %w", err)
	}
	return nil
}

func signalVerifiedGroup(home client.Home, owner *Owner, sig syscall.Signal) error {
	current, err := verifiedOwner(home)
	if err != nil {
		return fmt.Errorf("identity lost before signal: %w", err)
	}
	if current.Pid != owner.Pid || current.Pgid != owner.Pgid {
		return errors.New("owner identity changed before signal")
	}
	members, err := processGroupMembers(owner.Pgid)
	if err != nil {
		return fmt.Errorf("daemon process-group identity unavailable: %w", err)
	}
	if !containsPID(members, owner.Pid) {
		return errors.New("recorded daemon process is absent before signal")
	}
	if err := syscall.Kill(-owner.Pgid, sig); err != nil {
		return fmt.Errorf("signal daemon process group %d: %w", owner.Pgid, err)
	}
	return nil
}

func stopWithoutOwner(home client.Home) error {
	if _, err := os.Stat(home.Dir); errors.Is(err, fs.ErrNotExist) {
		return nil
	} else if err != nil {
		return fmt.Errorf("cannot inspect stop target: %w", err)
	}

	if err := verifyPIDFileIsNotLive(home); err != nil {
		return err
	}
	state, holder := client.ProbeLock(home.LockPath())
	if state == client.LockHeld {
		return fmt.Errorf("home lock is held by pid %d without a verified owner", holder)
	}
	if state == client.LockPermission {
		return errors.New("home lock permission is unknown")
	}
	for _, socket := range socketPaths(home) {
		if client.Probe(socket) == client.SocketLive {
			return fmt.Errorf("socket is live without a verified owner: %s", socket)
		}
	}
	return cleanupStopped(home, nil)
}

func verifyPIDFileIsNotLive(home client.Home) error {
	b, err := os.ReadFile(home.PIDPath())
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("cannot inspect daemon PID metadata: %w", err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil || pid <= 1 {
		return errors.New("refusing malformed daemon PID metadata")
	}
	if _, err := observeProcess(pid); err == nil {
		return fmt.Errorf("refusing to signal unverified pid %d", pid)
	} else if !errors.Is(err, errProcessAbsent) {
		return fmt.Errorf("daemon PID identity is unknown: %w", err)
	}
	return nil
}

func waitForStopped(home client.Home, owner *Owner, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	var last error
	for {
		if err := stopObservation(home, owner); err == nil {
			return nil
		} else {
			last = err
		}
		if !time.Now().Before(deadline) {
			return last
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func stopObservation(home client.Home, owner *Owner) error {
	state, holder := client.ProbeLock(home.LockPath())
	if state == client.LockHeld {
		if owner == nil || holder != owner.Pid {
			return fmt.Errorf("home lock remains held by pid %d", holder)
		}
		return errors.New("home lock remains held")
	}
	if state == client.LockPermission {
		return errors.New("home lock permission is unknown")
	}

	if owner != nil {
		if observed, err := observeProcess(owner.Pid); err == nil {
			if observed.Pgid != owner.Pgid || observed.Starttime != owner.Starttime || observed.Exe != owner.Exe {
				return errors.New("daemon process identity changed during stop")
			}
			return errors.New("daemon process remains live")
		} else if !errors.Is(err, errProcessAbsent) {
			return fmt.Errorf("daemon process liveness is unknown: %w", err)
		}
		members, err := processGroupMembers(owner.Pgid)
		if err != nil {
			return fmt.Errorf("daemon process-group liveness is unknown: %w", err)
		}
		if len(members) != 0 {
			return errors.New("daemon process group remains live")
		}
	}

	for _, socket := range socketPaths(home) {
		if client.Probe(socket) == client.SocketLive {
			return fmt.Errorf("socket remains live: %s", socket)
		}
	}
	if err := runnersSettled(home); err != nil {
		return err
	}
	return nil
}

func cleanupStopped(home client.Home, owner *Owner) error {
	lock, err := client.AcquireLock(home.LockPath())
	if err != nil {
		if errors.Is(err, client.ErrLockBusy) {
			return errors.New("stop incomplete: home lock was acquired by another process")
		}
		return fmt.Errorf("stop cleanup cannot acquire home lock: %w", err)
	}
	defer lock.Close()

	if owner != nil {
		if _, err := observeProcess(owner.Pid); err == nil {
			return errors.New("stop cleanup found the recorded daemon process live")
		} else if !errors.Is(err, errProcessAbsent) {
			return fmt.Errorf("stop cleanup cannot verify daemon absence: %w", err)
		}
	}
	if err := runnersSettled(home); err != nil {
		return err
	}
	for _, socket := range socketPaths(home) {
		state := client.Probe(socket)
		if state == client.SocketLive {
			return fmt.Errorf("refusing to remove live socket: %s", socket)
		}
		if err := removeStaleArtifact(socket); err != nil {
			return err
		}
	}
	for _, metadata := range []string{home.OwnerPath(), home.PIDPath()} {
		if err := removeStaleArtifact(metadata); err != nil {
			return err
		}
	}
	return nil
}

func removeStaleArtifact(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("cannot inspect lifecycle artifact %s: %w", path, err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("refusing symlink lifecycle artifact: %s", path)
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("remove stale lifecycle artifact %s: %w", path, err)
	}
	return nil
}

func socketPaths(home client.Home) []string {
	return []string{home.PrivilegedSocket(), home.APISocket(), home.BossSocket()}
}

func containsPID(pids []int, want int) bool {
	for _, pid := range pids {
		if pid == want {
			return true
		}
	}
	return false
}

type runnerManifest struct {
	State                string `json:"state"`
	RunnerPID            int    `json:"runner_pid"`
	RunnerExecutablePath string `json:"runner_executable_path"`
	PGID                 int    `json:"pgid"`
}

func runnersSettled(home client.Home) error {
	paths, err := filepath.Glob(filepath.Join(home.Dir, "runtime", "attempts", "*", "manifest.json"))
	if err != nil {
		return fmt.Errorf("runner inventory glob failed: %w", err)
	}
	for _, path := range paths {
		info, err := os.Stat(path)
		if err != nil {
			return fmt.Errorf("runner inventory stat failed: %w", err)
		}
		if info.Size() > 1<<20 {
			return fmt.Errorf("runner inventory is oversized: %s", path)
		}
		body, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("runner inventory read failed: %w", err)
		}
		var manifest runnerManifest
		if err := json.Unmarshal(body, &manifest); err != nil {
			return fmt.Errorf("runner inventory is malformed: %s", path)
		}
		if manifest.PGID <= 1 {
			if manifest.State == "starting" || manifest.State == "running" || manifest.State == "terminating" {
				return fmt.Errorf("runner inventory has no process-group identity: %s", path)
			}
			continue
		}
		members, err := processGroupMembers(manifest.PGID)
		if err != nil {
			return fmt.Errorf("runner liveness is unknown: %s", path)
		}
		if len(members) == 0 {
			continue
		}
		if manifest.RunnerPID <= 1 {
			return fmt.Errorf("runner process identity is missing: %s", path)
		}
		observed, err := observeProcess(manifest.RunnerPID)
		if err != nil {
			return fmt.Errorf("runner process identity is unknown: %s", path)
		}
		if manifest.RunnerExecutablePath != "" && filepath.Base(observed.Exe) != filepath.Base(manifest.RunnerExecutablePath) {
			return fmt.Errorf("runner executable identity changed: %s", path)
		}
		return fmt.Errorf("runner process group remains live: %s", path)
	}
	return nil
}

func normalizeHome(home client.Home) (client.Home, error) {
	abs, err := filepath.Abs(home.Dir)
	if err != nil {
		return client.Home{}, err
	}
	if resolved, resolveErr := filepath.EvalSymlinks(abs); resolveErr == nil {
		abs = resolved
	} else if !errors.Is(resolveErr, fs.ErrNotExist) {
		return client.Home{}, resolveErr
	}
	return client.Home{Dir: filepath.Clean(abs)}, nil
}
