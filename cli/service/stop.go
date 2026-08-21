package service

import (
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/douglasjarquin/consigliere/cli/client"
)

func Restart(home client.Home) error {
	if err := Stop(home); err != nil {
		return err
	}
	return Start(home)
}

func Stop(home client.Home) error {
	if runtime.GOOS == "darwin" {
		if _, err := os.Stat(PlistPath()); err == nil {
			_ = launchctl("bootout", "gui/"+strconv.Itoa(os.Getuid())+"/"+Label)
		}
	}
	_ = requestShutdown(home)

	owner, identErr := verifiedOwner(home)
	if identErr != nil {
		if foreignPID(home) {
			return fmt.Errorf("refusing to signal unverified pid: %w", identErr)
		}
		if stillLive(home) {
			return fmt.Errorf("daemon still live: %w", identErr)
		}
		_ = os.Remove(home.PIDPath())
		return nil
	}

	if err := signalVerified(owner, syscall.SIGTERM); err != nil {
		return err
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if !stillLive(home) && !processAlive(owner.Pid) {
			_ = os.Remove(home.PIDPath())
			return nil
		}
		time.Sleep(200 * time.Millisecond)
	}

	if err := identityMatches(home, owner); err != nil {
		if stillLive(home) {
			return fmt.Errorf("stop incomplete: %w", err)
		}
		_ = os.Remove(home.PIDPath())
		return nil
	}
	if err := signalVerified(owner, syscall.SIGKILL); err != nil {
		return err
	}
	time.Sleep(200 * time.Millisecond)
	if stillLive(home) || processAlive(owner.Pid) {
		return fmt.Errorf("daemon still owns home %s after stop", home.Dir)
	}
	_ = os.Remove(home.PIDPath())
	return nil
}

func requestShutdown(home client.Home) error {
	secret, err := home.BossSecret()
	if err != nil || secret == "" {
		return err
	}
	d := client.NewBossDialer(home)
	d.Secret = secret
	d.ReadTimeout = 2 * time.Second
	_, err = d.Call("daemon.shutdown", nil, "", "")
	return err
}

func signalVerified(owner *Owner, sig syscall.Signal) error {
	if err := identityMatches(client.Home{Dir: owner.Home}, owner); err != nil {
		return fmt.Errorf("identity lost before signal: %w", err)
	}
	proc, err := os.FindProcess(owner.Pid)
	if err != nil {
		return err
	}
	return proc.Signal(sig)
}

func stillLive(home client.Home) bool {
	state, _ := client.ProbeLock(home.LockPath())
	if state == client.LockHeld {
		return true
	}
	return client.Probe(home.PrivilegedSocket()) == client.SocketLive ||
		client.Probe(home.APISocket()) == client.SocketLive
}

func foreignPID(home client.Home) bool {
	pid := readPID(home)
	return pid > 1 && processAlive(pid)
}

func readPID(home client.Home) int {
	b, err := os.ReadFile(home.PIDPath())
	if err != nil {
		return 0
	}
	n, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	return n
}
