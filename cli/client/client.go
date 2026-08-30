package client

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"time"
)

const (
	ExitOK           = 0
	ExitError        = 1
	ExitUsage        = 2
	ExitAbsent       = 3
	ExitStale        = 4
	ExitUnauthorized = 5
	ExitProtocol     = 6
	ExitMalformed    = 7
)

var (
	ErrAbsent       = errors.New("daemon absent")
	ErrStale        = errors.New("daemon stale")
	ErrUnauthorized = errors.New("unauthorized")
	ErrProtocol     = errors.New("protocol version mismatch")
	ErrMalformed    = errors.New("malformed daemon response")
)

type ErrorBody struct {
	Code   string `json:"code"`
	Reason string `json:"reason"`
}

type Response struct {
	V       int             `json:"v"`
	ID      string          `json:"id"`
	OK      bool            `json:"ok"`
	Payload json.RawMessage `json:"payload"`
	Error   *ErrorBody      `json:"error"`
}

type Request struct {
	V                int            `json:"v"`
	ID               string         `json:"id"`
	Op               string         `json:"op"`
	OperationVersion int            `json:"operation_version,omitempty"`
	Actor            map[string]any `json:"actor"`
	Payload          map[string]any `json:"payload,omitempty"`
	Secret           string         `json:"secret,omitempty"`
	IdempotencyKey   string         `json:"idempotency_key,omitempty"`
	CanonicalHash    string         `json:"canonical_hash,omitempty"`
}

type Dialer struct {
	Home           Home
	Socket         string
	ConnectTimeout time.Duration
	ReadTimeout    time.Duration
	Version        int
	Secret         string
	Principal      string
	AuthorityScope string
}

func NewDialer(home Home) Dialer {
	return Dialer{
		Home:           home,
		Socket:         home.APISocket(),
		ConnectTimeout: 2 * time.Second,
		ReadTimeout:    30 * time.Second,
		Version:        ProtocolVersion,
	}
}

func NewBossDialer(home Home) Dialer {
	d := NewDialer(home)
	d.Socket = home.PrivilegedSocket()
	return d
}

func NewAttemptDialer(socket, secret, authorityScope string) Dialer {
	return Dialer{
		Home:           Home{Dir: filepath.Dir(socket)},
		Socket:         socket,
		ConnectTimeout: 2 * time.Second,
		ReadTimeout:    30 * time.Second,
		Version:        ProtocolVersion,
		Secret:         secret,
		Principal:      "attempt",
		AuthorityScope: authorityScope,
	}
}

func (d Dialer) Call(op string, payload map[string]any, id, idem string) (*Response, error) {
	state := Probe(d.Socket)
	switch state {
	case SocketAbsent:
		return nil, ErrAbsent
	case SocketStale:
		return nil, ErrStale
	}

	secret := d.Secret
	principal := d.Principal
	if principal == "" {
		principal = "model_advisory"
	}
	switch principal {
	case "attempt":
		if secret == "" {
			return nil, fmt.Errorf("attempt capability missing")
		}
		if d.AuthorityScope == "" {
			return nil, fmt.Errorf("attempt authority scope missing")
		}
	default:
		if d.Socket == d.Home.PrivilegedSocket() {
			principal = "boss"
			if secret == "" {
				s, err := d.Home.BossSecret()
				if err != nil {
					return nil, fmt.Errorf("boss credential: %w", err)
				}
				secret = s
			}
		} else if secret == "" && d.Socket == d.Home.APISocket() {
			s, err := d.Home.AdvisorySecret()
			if err != nil {
				return nil, fmt.Errorf("advisory credential: %w", err)
			}
			secret = s
		}
	}

	if payload == nil {
		payload = map[string]any{}
	}
	if id == "" {
		id = fmt.Sprintf("req-%d", time.Now().UnixNano())
	}
	version, mutating := operationVersion(op)
	if mutating && idem == "" {
		idem = generatedIdempotencyKey()
	}
	canonicalHash := ""
	if mutating {
		var err error
		scope := canonicalScope(principal)
		if d.AuthorityScope != "" {
			scope = d.AuthorityScope
		}
		canonicalHash, err = CanonicalRequestHash(scope, op, version, idem, payload)
		if err != nil {
			return nil, err
		}
	}

	req := Request{
		V:                d.Version,
		ID:               id,
		Op:               op,
		OperationVersion: version,
		Actor:            map[string]any{"principal": principal},
		Payload:          payload,
		Secret:           secret,
		IdempotencyKey:   idem,
		CanonicalHash:    canonicalHash,
	}
	body, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}
	body = append(body, '\n')

	attempts := 1
	if mutating {
		attempts = 2
	}
	for attempt := 0; attempt < attempts; attempt++ {
		resp, callErr := d.callOnce(body)
		if callErr == nil || !mutating || attempt+1 == attempts || !retryable(callErr) {
			return resp, callErr
		}
		boundedRetryDelay()
	}
	return nil, ErrMalformed
}

func (d Dialer) callOnce(body []byte) (*Response, error) {
	conn, err := net.DialTimeout("unix", d.Socket, d.ConnectTimeout)
	if err != nil {
		if Probe(d.Socket) == SocketStale {
			return nil, ErrStale
		}
		return nil, fmt.Errorf("daemon unavailable: %w", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(d.ReadTimeout))

	if _, err := conn.Write(body); err != nil {
		return nil, err
	}
	line, err := bufio.NewReader(conn).ReadBytes('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, err
	}
	if len(line) == 0 {
		return nil, ErrMalformed
	}

	var resp Response
	if err := json.Unmarshal(line, &resp); err != nil {
		return nil, ErrMalformed
	}
	if resp.Error != nil {
		switch resp.Error.Code {
		case "unauthorized":
			return &resp, ErrUnauthorized
		case "protocol_version":
			return &resp, ErrProtocol
		}
	}
	return &resp, nil
}

func retryable(err error) bool {
	return errors.Is(err, ErrMalformed) || errors.Is(err, ErrStale)
}

func ExitFor(err error, resp *Response) int {
	if err == nil {
		if resp != nil && !resp.OK {
			return ExitError
		}
		return ExitOK
	}
	switch {
	case errors.Is(err, ErrAbsent):
		return ExitAbsent
	case errors.Is(err, ErrStale):
		return ExitStale
	case errors.Is(err, ErrUnauthorized):
		return ExitUnauthorized
	case errors.Is(err, ErrProtocol):
		return ExitProtocol
	case errors.Is(err, ErrMalformed):
		return ExitMalformed
	default:
		return ExitError
	}
}

func PrintError(w io.Writer, err error, resp *Response) {
	if resp != nil && resp.Error != nil {
		fmt.Fprintf(w, "error: %s: %s\n", resp.Error.Code, resp.Error.Reason)
		return
	}
	if err != nil {
		fmt.Fprintf(w, "error: %s\n", err.Error())
	}
}

func EnsureNotRoot() error {
	if os.Geteuid() == 0 {
		return errors.New("refusing to run as root")
	}
	return nil
}
