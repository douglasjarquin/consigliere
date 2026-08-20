package client

import (
	"net"
	"os"
	"path/filepath"
	"time"
)

const (
	ProtocolVersion = 1
	ClientVersion   = "0.1.0"
)

type Home struct {
	Dir string
}

func ResolveHome() Home {
	dir := os.Getenv("CS_HOME")
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, ".consigliere")
	}
	return Home{Dir: dir}
}

func (h Home) PrivilegedSocket() string { return filepath.Join(h.Dir, "priv.sock") }
func (h Home) APISocket() string        { return filepath.Join(h.Dir, "api.sock") }
func (h Home) BossSocket() string       { return filepath.Join(h.Dir, "boss.sock") }
func (h Home) LockPath() string         { return filepath.Join(h.Dir, "lock") }
func (h Home) OwnerPath() string        { return filepath.Join(h.Dir, "owner.json") }
func (h Home) LastErrorPath() string    { return filepath.Join(h.Dir, "last_error.log") }
func (h Home) DatabasePath() string     { return filepath.Join(h.Dir, "consigliere.db") }
func (h Home) LogsDir() string          { return filepath.Join(h.Dir, "logs") }
func (h Home) CredentialPath() string   { return filepath.Join(h.Dir, "credentials", "boss") }
func (h Home) AdvisoryCredentialPath() string {
	return filepath.Join(h.Dir, "credentials", "advisory")
}
func (h Home) PIDPath() string          { return filepath.Join(h.Dir, "csd.pid") }

func (h Home) BossSecret() (string, error) {
	b, err := os.ReadFile(h.CredentialPath())
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func (h Home) AdvisorySecret() (string, error) {
	b, err := os.ReadFile(h.AdvisoryCredentialPath())
	if err != nil {
		return "", err
	}
	return string(b), nil
}

type SocketState string

const (
	SocketLive   SocketState = "live"
	SocketStale  SocketState = "stale"
	SocketAbsent SocketState = "absent"
)

type LockState string

const (
	LockHeld    LockState = "held"
	LockUnowned LockState = "unowned"
	LockStale   LockState = "stale"
)

func ProbeLock(path string) (LockState, int) {
	fd, err := unixOpen(path)
	if err != nil {
		if os.IsNotExist(err) {
			return LockUnowned, 0
		}
		if _, statErr := os.Stat(path); statErr == nil {
			return LockStale, 0
		}
		return LockUnowned, 0
	}
	defer unixClose(fd)

	held, pid, err := unixGetlk(fd)
	if err != nil {
		return LockStale, 0
	}
	if held {
		return LockHeld, pid
	}
	return LockStale, 0
}

func Probe(path string) SocketState {
	if _, err := os.Stat(path); err != nil {
		return SocketAbsent
	}
	conn, err := net.DialTimeout("unix", path, 200*time.Millisecond)
	if err != nil {
		return SocketStale
	}
	_ = conn.Close()
	return SocketLive
}

func (h Home) LastError() string {
	b, err := os.ReadFile(h.LastErrorPath())
	if err != nil {
		return ""
	}
	return string(b)
}
