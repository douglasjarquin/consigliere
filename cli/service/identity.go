package service

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"

	"github.com/douglasjarquin/consigliere/cli/client"
)

type Owner struct {
	Pid       int    `json:"pid"`
	Home      string `json:"home"`
	UID       int    `json:"uid"`
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
	out, err := exec.Command("ps", "-o", "lstart=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return ""
	}
	return strings.Join(strings.Fields(string(out)), " ")
}

func processExe(pid int) string {
	out, err := exec.Command("ps", "-o", "comm=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func processAlive(pid int) bool {
	proc, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	return proc.Signal(syscall.Signal(0)) == nil
}

func identityMatches(home client.Home, owner *Owner) error {
	if owner.Home != "" && owner.Home != home.Dir {
		return fmt.Errorf("owner home %s does not match %s", owner.Home, home.Dir)
	}
	if owner.UID != 0 && owner.UID != os.Getuid() {
		return fmt.Errorf("owner uid %d does not match %d", owner.UID, os.Getuid())
	}
	if !processAlive(owner.Pid) {
		return fmt.Errorf("owner pid %d is not alive", owner.Pid)
	}
	if owner.Starttime != "" {
		got := processStarttime(owner.Pid)
		if got != "" && got != owner.Starttime {
			return fmt.Errorf("pid %d reused (starttime %s != %s)", owner.Pid, got, owner.Starttime)
		}
	}
	if owner.Exe != "" {
		got := processExe(owner.Pid)
		if got != "" && got != owner.Exe {
			return fmt.Errorf("pid %d exe %s != %s", owner.Pid, got, owner.Exe)
		}
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
	if state == client.LockHeld && holder > 1 && holder != owner.Pid {
		return nil, fmt.Errorf("lock holder %d is not owner pid %d", holder, owner.Pid)
	}
	return owner, nil
}
