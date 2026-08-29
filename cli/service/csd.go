package service

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/douglasjarquin/consigliere/cli/client"
)

const Label = "ai.consigliere.csd"

func Run(args []string, stdout, stderr io.Writer) int {
	if err := client.EnsureNotRoot(); err != nil {
		fmt.Fprintln(stderr, err.Error())
		return client.ExitError
	}
	if len(args) == 0 {
		fmt.Fprint(stdout, usage())
		return client.ExitUsage
	}
	home := client.ResolveHome()
	cmd := args[0]
	opts, _ := parseFlags(args[1:])
	switch cmd {
	case "foreground":
		if err := Foreground(home); err != nil {
			fmt.Fprintln(stderr, err.Error())
			return client.ExitError
		}
		return client.ExitOK
	case "start":
		if err := Start(home); err != nil {
			fmt.Fprintln(stderr, err.Error())
			return client.ExitError
		}
		fmt.Fprintf(stdout, "started home=%s\n", home.Dir)
		return client.ExitOK
	case "stop":
		if err := Stop(home); err != nil {
			fmt.Fprintln(stderr, err.Error())
			return client.ExitError
		}
		fmt.Fprintln(stdout, "stopped")
		return client.ExitOK
	case "restart":
		if err := Restart(home); err != nil {
			fmt.Fprintln(stderr, err.Error())
			return client.ExitError
		}
		fmt.Fprintln(stdout, "restarted")
		return client.ExitOK
	case "status":
		return Status(home, stdout)
	case "logs":
		return Logs(home, stdout, stderr)
	case "install":
		if err := Install(home, opts["prefix"], opts["no_load"] == "true"); err != nil {
			fmt.Fprintln(stderr, err.Error())
			return client.ExitError
		}
		fmt.Fprintln(stdout, PlistPathFor(home))
		return client.ExitOK
	case "uninstall":
		if err := Uninstall(home); err != nil {
			fmt.Fprintln(stderr, err.Error())
			return client.ExitError
		}
		fmt.Fprintln(stdout, "uninstalled")
		return client.ExitOK
	case "migrate":
		if err := Migrate(home); err != nil {
			fmt.Fprintln(stderr, err.Error())
			return client.ExitError
		}
		fmt.Fprintf(stdout, "migrated %s\n", home.DatabasePath())
		return client.ExitOK
	case "help", "--help", "-h":
		fmt.Fprint(stdout, usage())
		return client.ExitOK
	default:
		fmt.Fprintf(stderr, "unknown command: %s\n", cmd)
		fmt.Fprint(stderr, usage())
		return client.ExitUsage
	}
}

func usage() string {
	return `csd - consigliere daemon

csd foreground
csd start
csd stop
csd restart
csd status
csd logs
csd migrate
csd install [--prefix DIR] [--no-load]
csd uninstall
`
}

func parseFlags(args []string) (map[string]string, []string) {
	opts := map[string]string{}
	var pos []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if !strings.HasPrefix(a, "--") {
			pos = append(pos, a)
			continue
		}
		key := strings.ReplaceAll(strings.TrimPrefix(a, "--"), "-", "_")
		if i+1 < len(args) && !strings.HasPrefix(args[i+1], "-") {
			i++
			opts[key] = args[i]
			continue
		}
		opts[key] = "true"
	}
	return opts, pos
}

func ReleaseRoot() (string, error) {
	if v := os.Getenv("CS_RELEASE"); v != "" {
		return v, nil
	}
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	cand := filepath.Join(filepath.Dir(exe), "..", "libexec", "consigliere_daemon")
	if _, err := os.Stat(filepath.Join(cand, "bin", "consigliere_daemon")); err == nil {
		return cand, nil
	}
	return "", fmt.Errorf("OTP release not found; set CS_RELEASE")
}

func releaseBin() (string, error) {
	root, err := ReleaseRoot()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, "bin", "consigliere_daemon"), nil
}

func Foreground(home client.Home) error {
	bin, err := releaseBin()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(home.LogsDir(), 0o700); err != nil {
		return err
	}
	env := append(os.Environ(), "CS_HOME="+home.Dir)
	return syscall.Exec(bin, []string{bin, "start"}, env)
}

func Start(home client.Home) error {
	target, err := normalizeHome(home)
	if err != nil {
		return fmt.Errorf("start target: %w", err)
	}
	home = target
	if client.Probe(home.PrivilegedSocket()) == client.SocketLive {
		if _, err := verifiedOwner(home); err != nil {
			return fmt.Errorf("refusing unverified live daemon: %w", err)
		}
		return nil
	}
	lock, holder := client.ProbeLock(home.LockPath())
	if lock == client.LockHeld {
		return fmt.Errorf("home is already owned by pid %d", holder)
	}
	if lock == client.LockPermission {
		return errors.New("home lock permission is unknown")
	}
	for _, socket := range []string{home.APISocket(), home.BossSocket()} {
		if client.Probe(socket) == client.SocketLive {
			return fmt.Errorf("live socket exists without a verified daemon: %s", socket)
		}
	}
	if runtime.GOOS == "darwin" {
		plistPath := PlistPathFor(home)
		label := labelForHome(home)
		if _, err := os.Stat(plistPath); err == nil && os.Getenv("CS_CSD_FORCE_BACKGROUND") == "" {
			if err := launchctl("bootstrap", "gui/"+strconv.Itoa(os.Getuid()), plistPath); err != nil {
				_ = launchctl("kickstart", "-k", "gui/"+strconv.Itoa(os.Getuid())+"/"+label)
			}
			return waitLive(home, 30*time.Second)
		}
	}
	return startBackground(home)
}

func startBackground(home client.Home) error {
	bin, err := releaseBin()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(home.Dir, 0o700); err != nil {
		return err
	}
	if err := os.MkdirAll(home.LogsDir(), 0o700); err != nil {
		return err
	}
	logf, err := os.OpenFile(filepath.Join(home.LogsDir(), "csd.stdout.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	cmd := exec.Command(bin, "start")
	cmd.Env = append(os.Environ(), "CS_HOME="+home.Dir)
	cmd.Stdout = logf
	cmd.Stderr = logf
	cmd.Stdin = nil
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		logf.Close()
		return err
	}
	_ = os.WriteFile(home.PIDPath(), []byte(strconv.Itoa(cmd.Process.Pid)+"\n"), 0o600)
	go func() {
		_ = cmd.Wait()
		logf.Close()
	}()
	return waitLive(home, 30*time.Second)
}

func waitLive(home client.Home, d time.Duration) error {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if client.Probe(home.PrivilegedSocket()) == client.SocketLive &&
			client.Probe(home.APISocket()) == client.SocketLive {
			if _, err := verifiedOwner(home); err == nil {
				return nil
			}
		}
		time.Sleep(200 * time.Millisecond)
	}
	if err := home.LastError(); err != "" {
		return fmt.Errorf("daemon did not become live: %s", strings.TrimSpace(err))
	}
	return fmt.Errorf("daemon did not become live")
}

func Status(home client.Home, stdout io.Writer) int {
	priv := client.Probe(home.PrivilegedSocket())
	lock, holder := client.ProbeLock(home.LockPath())
	ownerState := ownerDiagnostic(home)
	fmt.Fprintf(stdout, "home=%s priv=%s api=%s boss=%s lock=%s holder=%d owner=%s\n",
		home.Dir, priv, client.Probe(home.APISocket()), client.Probe(home.BossSocket()),
		lock, holder, ownerState)
	if priv == client.SocketLive {
		return client.ExitOK
	}
	if lock == client.LockHeld {
		return client.ExitOK
	}
	if priv == client.SocketStale {
		return client.ExitStale
	}
	return client.ExitAbsent
}

func ownerDiagnostic(home client.Home) string {
	owner, err := readOwner(home)
	if err != nil {
		if os.IsPermission(err) {
			return "permission"
		}
		if os.IsNotExist(err) {
			return "absent"
		}
		return "malformed"
	}
	if err := identityMatches(home, owner); err != nil {
		return "stale"
	}
	return "verified"
}

func Logs(home client.Home, stdout, stderr io.Writer) int {
	paths := []string{
		filepath.Join(home.LogsDir(), "csd.stdout.log"),
		filepath.Join(home.LogsDir(), "csd.stderr.log"),
		home.LastErrorPath(),
	}
	found := false
	for _, p := range paths {
		b, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		found = true
		fmt.Fprintf(stdout, "== %s ==\n%s", p, string(b))
	}
	if !found {
		fmt.Fprintln(stderr, "no logs")
		return client.ExitError
	}
	return client.ExitOK
}

func Migrate(home client.Home) error {
	bin, err := releaseBin()
	if err != nil {
		return err
	}
	cmd := exec.Command(bin, "eval", "Consigliere.Release.migrate()")
	cmd.Env = append(os.Environ(), "CS_HOME="+home.Dir)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func AgentsDir() string {
	if v := os.Getenv("CS_LAUNCH_AGENTS_DIR"); v != "" {
		return v
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "LaunchAgents")
}

func PlistPath() string {
	return filepath.Join(AgentsDir(), Label+".plist")
}

func PlistPathFor(home client.Home) string {
	return filepath.Join(AgentsDir(), labelForHome(home)+".plist")
}

func labelForHome(home client.Home) string {
	target, err := normalizeHome(home)
	directory := home.Dir
	if err == nil {
		directory = target.Dir
	}
	sum := sha256.Sum256([]byte(directory))
	return Label + "-" + hex.EncodeToString(sum[:6])
}

func Install(home client.Home, prefix string, noLoad bool) error {
	target, err := normalizeHome(home)
	if err != nil {
		return fmt.Errorf("install target: %w", err)
	}
	home = target
	if err := os.MkdirAll(home.Dir, 0o700); err != nil {
		return err
	}
	if err := os.MkdirAll(home.LogsDir(), 0o700); err != nil {
		return err
	}
	csdPath, err := os.Executable()
	if err != nil {
		return err
	}
	if prefix != "" {
		if err := os.MkdirAll(filepath.Join(prefix, "bin"), 0o755); err != nil {
			return err
		}
		dest := filepath.Join(prefix, "bin", "csd")
		if err := copyFile(csdPath, dest); err != nil {
			return err
		}
		csPath := filepath.Join(filepath.Dir(csdPath), "cs")
		if _, err := os.Stat(csPath); err == nil {
			_ = copyFile(csPath, filepath.Join(prefix, "bin", "cs"))
		}
		csdPath = dest
		if rel, err := ReleaseRoot(); err == nil {
			os.Setenv("CS_RELEASE", rel)
		}
	}
	rel, _ := ReleaseRoot()
	body := Plist(labelForHome(home), csdPath, home.Dir, rel)
	if err := os.MkdirAll(filepath.Dir(PlistPathFor(home)), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(PlistPathFor(home), []byte(body), 0o644); err != nil {
		return err
	}
	if runtime.GOOS == "darwin" && !noLoad {
		_ = launchctl("bootout", "gui/"+strconv.Itoa(os.Getuid())+"/"+labelForHome(home))
		if err := launchctl("bootstrap", "gui/"+strconv.Itoa(os.Getuid()), PlistPathFor(home)); err != nil {
			return err
		}
	}
	return nil
}

func Uninstall(home client.Home) error {
	target, err := normalizeHome(home)
	if err != nil {
		return fmt.Errorf("uninstall target: %w", err)
	}
	home = target
	if runtime.GOOS == "darwin" {
		_ = launchctl("bootout", "gui/"+strconv.Itoa(os.Getuid())+"/"+labelForHome(home))
	}
	return os.Remove(PlistPathFor(home))
}

func Plist(label, bin, home, release string) string {
	env := fmt.Sprintf(`      <key>CS_HOME</key>
      <string>%s</string>
`, xmlEscape(home))
	if release != "" {
		env += fmt.Sprintf(`      <key>CS_RELEASE</key>
      <string>%s</string>
`, xmlEscape(release))
	}
	stdout := filepath.Join(home, "logs", "csd.stdout.log")
	stderr := filepath.Join(home, "logs", "csd.stderr.log")
	return fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>%s</string>
  <key>ProgramArguments</key>
  <array>
    <string>%s</string>
    <string>foreground</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
%s  </dict>
  <key>WorkingDirectory</key>
  <string>%s</string>
  <key>StandardOutPath</key>
  <string>%s</string>
  <key>StandardErrorPath</key>
  <string>%s</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>ProcessType</key>
  <string>Background</string>
</dict>
</plist>
`, xmlEscape(label), xmlEscape(bin), env, xmlEscape(home), xmlEscape(stdout), xmlEscape(stderr))
}

func xmlEscape(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	return s
}

func launchctl(args ...string) error {
	cmd := exec.Command("launchctl", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("launchctl %s: %s", strings.Join(args, " "), strings.TrimSpace(string(out)))
	}
	return nil
}

func copyFile(src, dst string) error {
	in, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, in, 0o755)
}
