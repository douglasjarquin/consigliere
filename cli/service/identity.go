package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/douglasjarquin/consigliere/cli/client"
)

var (
	errProcessAbsent      = errors.New("process is absent")
	errProcessObservation = errors.New("process observation failed")
)

type Owner struct {
	Pid       int    `json:"pid"`
	Home      string `json:"home"`
	UID       int    `json:"uid"`
	Pgid      int    `json:"pgid"`
	Release   string `json:"release"`
	Starttime string `json:"starttime"`
	Exe       string `json:"exe"`
	Lock      string `json:"lock"`
}

func readOwner(home client.Home) (*Owner, error) {
	b, err := os.ReadFile(home.OwnerPath())
	if err != nil {
		return nil, err
	}
	var o Owner
	if err := json.Unmarshal(b, &o); err != nil {
		return nil, fmt.Errorf("corrupt owner.json: %w", err)
	}
	if o.Pid <= 1 {
		return nil, fmt.Errorf("owner.json pid is not a process identity")
	}
	return &o, nil
}

func processStarttime(pid int) string {
	out, err := psValue(pid, "lstart=")
	if err != nil {
		return ""
	}
	return strings.Join(strings.Fields(string(out)), " ")
}

func processExe(pid int) string {
	out, err := psValue(pid, "comm=")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func processGroupID(pid int) int {
	out, err := psValue(pid, "pgid=")
	if err != nil {
		return 0
	}
	group, err := strconv.Atoi(strings.TrimSpace(out))
	if err != nil {
		return 0
	}
	return group
}

func processAlive(pid int) bool {
	_, err := observeProcess(pid)
	return err == nil
}

func processGroupMembers(pgid int) ([]int, error) {
	if pgid <= 1 {
		return nil, fmt.Errorf("%w: invalid process group", errProcessObservation)
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "ps", "-axo", "pid=,pgid=,stat=")
	out, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		return nil, fmt.Errorf("%w: ps timed out", errProcessObservation)
	}
	if err != nil {
		return nil, fmt.Errorf("%w: ps failed", errProcessObservation)
	}

	var members []int
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		pid, pidErr := strconv.Atoi(fields[0])
		group, groupErr := strconv.Atoi(fields[1])
		if pidErr == nil && groupErr == nil && group == pgid && !strings.HasPrefix(fields[2], "Z") {
			members = append(members, pid)
		}
	}
	return members, nil
}

func identityMatches(home client.Home, owner *Owner) error {
	if owner == nil {
		return errors.New("owner metadata is missing")
	}
	if owner.Home == "" {
		return errors.New("owner metadata has no home identity")
	}
	expectedHome, err := canonicalHome(home.Dir)
	if err != nil {
		return fmt.Errorf("target home is not canonical: %w", err)
	}
	recordedHome, err := canonicalHome(owner.Home)
	if err != nil {
		return fmt.Errorf("owner home is not canonical: %w", err)
	}
	if recordedHome != expectedHome {
		return fmt.Errorf("owner home %s does not match %s", owner.Home, home.Dir)
	}
	if owner.UID != os.Getuid() {
		return fmt.Errorf("owner uid %d does not match %d", owner.UID, os.Getuid())
	}
	if owner.Pid <= 1 {
		return errors.New("owner metadata has no process identity")
	}
	if owner.Pgid <= 1 {
		return errors.New("owner metadata has no process-group identity")
	}
	if owner.Starttime == "" || owner.Exe == "" || owner.Lock != "fcntl" {
		return errors.New("owner metadata has incomplete process identity")
	}

	observed, err := observeProcess(owner.Pid)
	if err != nil {
		return fmt.Errorf("owner process identity unavailable: %w", err)
	}
	if observed.Pgid != owner.Pgid {
		return fmt.Errorf("pid %d process group %d != %d", owner.Pid, observed.Pgid, owner.Pgid)
	}
	if observed.Starttime != owner.Starttime {
		return fmt.Errorf("pid %d reused (starttime %s != %s)", owner.Pid, observed.Starttime, owner.Starttime)
	}
	if observed.Exe != owner.Exe {
		return fmt.Errorf("pid %d exe %s != %s", owner.Pid, observed.Exe, owner.Exe)
	}
	return nil
}

func verifiedOwner(home client.Home) (*Owner, error) {
	owner, err := readOwner(home)
	if err != nil {
		return nil, err
	}
	if err := identityMatches(home, owner); err != nil {
		return nil, err
	}
	state, holder := client.ProbeLock(home.LockPath())
	if state != client.LockHeld {
		return nil, fmt.Errorf("home lock is not held by the recorded owner: %s", state)
	}
	if holder != owner.Pid {
		return nil, fmt.Errorf("lock holder %d is not owner pid %d", holder, owner.Pid)
	}
	return owner, nil
}

type observedProcess struct {
	Pid       int
	Pgid      int
	Starttime string
	Exe       string
}

func observeProcess(pid int) (observedProcess, error) {
	if pid <= 1 {
		return observedProcess{}, fmt.Errorf("%w: pid %d", errProcessAbsent, pid)
	}

	pidText, err := psValue(pid, "pid=")
	if err != nil {
		return observedProcess{}, err
	}
	observedPID, err := strconv.Atoi(strings.TrimSpace(pidText))
	if err != nil || observedPID != pid {
		return observedProcess{}, fmt.Errorf("%w: pid mismatch", errProcessObservation)
	}

	pgid := processGroupID(pid)
	if pgid <= 1 {
		return observedProcess{}, fmt.Errorf("%w: process group unavailable", errProcessObservation)
	}
	starttime, err := psValue(pid, "lstart=")
	if err != nil {
		return observedProcess{}, err
	}
	exe, err := psValue(pid, "comm=")
	if err != nil {
		return observedProcess{}, err
	}

	return observedProcess{
		Pid:       observedPID,
		Pgid:      pgid,
		Starttime: strings.Join(strings.Fields(starttime), " "),
		Exe:       strings.TrimSpace(exe),
	}, nil
}

func psValue(pid int, format string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "ps", "-o", format, "-p", strconv.Itoa(pid))
	out, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		return "", fmt.Errorf("%w: ps timed out", errProcessObservation)
	}
	trimmed := strings.TrimSpace(string(out))
	if trimmed == "" {
		return "", fmt.Errorf("%w: pid %d", errProcessAbsent, pid)
	}
	if err != nil {
		return "", fmt.Errorf("%w: ps failed", errProcessObservation)
	}
	return trimmed, nil
}

func canonicalHome(path string) (string, error) {
	if strings.TrimSpace(path) == "" {
		return "", errors.New("home path is empty")
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	resolved, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", err
	}
	return filepath.Clean(resolved), nil
}
