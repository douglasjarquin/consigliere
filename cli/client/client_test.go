package client

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func shortDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "csc-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

func serve(t *testing.T, handler func(map[string]any) map[string]any) (home Home, sock string) {
	t.Helper()
	dir := shortDir(t)
	home = Home{Dir: dir}
	os.MkdirAll(filepath.Join(dir, "credentials"), 0o700)
	os.WriteFile(home.CredentialPath(), []byte("secret"), 0o600)
	os.WriteFile(home.AdvisoryCredentialPath(), []byte("advisory"), 0o600)
	sock = home.PrivilegedSocket()
	listenUnix(t, home.PrivilegedSocket(), handler)
	listenUnix(t, home.APISocket(), handler)
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if Probe(home.PrivilegedSocket()) == SocketLive && Probe(home.APISocket()) == SocketLive {
			return home, sock
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("listener never became live")
	return home, sock
}

func listenUnix(t *testing.T, path string, handler func(map[string]any) map[string]any) {
	t.Helper()
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				line, err := bufio.NewReader(conn).ReadBytes('\n')
				if err != nil && err != io.EOF {
					return
				}
				if len(line) == 0 {
					return
				}
				var req map[string]any
				if json.Unmarshal(line, &req) != nil {
					conn.Write([]byte(`{"v":1,"ok":false,"error":{"code":"invalid","reason":"not json"}}` + "\n"))
					return
				}
				resp := handler(req)
				b, _ := json.Marshal(resp)
				conn.Write(append(b, '\n'))
			}(c)
		}
	}()
}

func TestPingAndJSON(t *testing.T) {
	home, _ := serve(t, func(req map[string]any) map[string]any {
		if req["op"] != "ping" {
			t.Errorf("op=%v", req["op"])
		}
		if req["secret"] != "advisory" {
			t.Errorf("missing secret")
		}
		if req["v"].(float64) != 1 {
			t.Errorf("v=%v", req["v"])
		}
		return map[string]any{"v": 1, "id": req["id"], "ok": true, "payload": map[string]any{"pong": true}}
	})
	t.Setenv("CS_HOME", home.Dir)
	var out, err strings.Builder
	code := Run([]string{"ping"}, &out, &err)
	if code != ExitOK {
		t.Fatalf("exit %d stderr=%s", code, err.String())
	}
	if !strings.Contains(out.String(), "pong") {
		t.Fatalf("out=%q", out.String())
	}

	out.Reset()
	err.Reset()
	code = Run([]string{"--json", "ping"}, &out, &err)
	if code != ExitOK {
		t.Fatalf("json exit %d", code)
	}
	if !strings.Contains(out.String(), `"ok":true`) {
		t.Fatalf("json out=%q", out.String())
	}
}

func TestProtocolMismatchAndMalformed(t *testing.T) {
	home, _ := serve(t, func(req map[string]any) map[string]any {
		return map[string]any{
			"v":  1,
			"id": req["id"],
			"ok": false,
			"error": map[string]any{
				"code":   "protocol_version",
				"reason": "unsupported version 99",
			},
		}
	})
	t.Setenv("CS_HOME", home.Dir)
	t.Setenv("CS_PROTOCOL_VERSION", "99")
	var out, errb strings.Builder
	code := Run([]string{"ping"}, &out, &errb)
	if code != ExitProtocol {
		t.Fatalf("exit %d want %d stderr=%s", code, ExitProtocol, errb.String())
	}
}

func TestUnauthorized(t *testing.T) {
	home, _ := serve(t, func(req map[string]any) map[string]any {
		return map[string]any{
			"v": 1, "id": req["id"], "ok": false,
			"error": map[string]any{"code": "unauthorized", "reason": "capability"},
		}
	})
	t.Setenv("CS_HOME", home.Dir)
	var out, errb strings.Builder
	code := Run([]string{"cancel", "mid"}, &out, &errb)
	if code != ExitUnauthorized {
		t.Fatalf("exit %d stderr=%s", code, errb.String())
	}
}

func TestAbsentAndStale(t *testing.T) {
	dir := shortDir(t)
	t.Setenv("CS_HOME", dir)
	var out, errb strings.Builder
	code := Run([]string{"ping"}, &out, &errb)
	if code != ExitAbsent {
		t.Fatalf("absent exit %d stderr=%s", code, errb.String())
	}

	os.WriteFile(filepath.Join(dir, "api.sock"), []byte("junk"), 0o600)
	errb.Reset()
	code = Run([]string{"ping"}, &out, &errb)
	if code != ExitStale {
		t.Fatalf("stale exit %d stderr=%s", code, errb.String())
	}
}

func TestWhyHumanOutput(t *testing.T) {
	home, _ := serve(t, func(req map[string]any) map[string]any {
		return map[string]any{
			"v":  1,
			"id": req["id"],
			"ok": true,
			"payload": map[string]any{
				"id":           "m1",
				"phase":        "awaiting_authorization",
				"runnable":     false,
				"reason":       "phase",
				"phase_reason": "no work authorization yet",
				"blockers":     []any{},
			},
		}
	})
	t.Setenv("CS_HOME", home.Dir)
	var out, errb strings.Builder
	code := Run([]string{"why", "m1"}, &out, &errb)
	if code != ExitOK {
		t.Fatalf("exit %d stderr=%s", code, errb.String())
	}
	if !strings.Contains(out.String(), "phase=awaiting_authorization") {
		t.Fatalf("out=%q", out.String())
	}
	if !strings.Contains(out.String(), "no work authorization yet") {
		t.Fatalf("missing phase reason: %q", out.String())
	}
}

func TestUnknownCommand(t *testing.T) {
	var out, errb strings.Builder
	code := Run([]string{"nope"}, &out, &errb)
	if code != ExitUsage {
		t.Fatalf("exit %d", code)
	}
}

func TestMapCommandAuthorizeMerge(t *testing.T) {
	op, payload, err := mapCommand("authorize-merge", []string{"mid"}, map[string]string{"pr": "12", "sha": "abc"})
	if err != nil {
		t.Fatal(err)
	}
	if op != "mission.grant_integration" {
		t.Fatalf("op=%s", op)
	}
	if payload["target_sha"] != "abc" || payload["target_pull_request"] != "12" {
		t.Fatalf("%v", payload)
	}
}

func TestMapCommandLocalV0Workflow(t *testing.T) {
	tests := []struct {
		name    string
		command string
		pos     []string
		opts    map[string]string
		wantOp  string
		want    map[string]any
	}{
		{
			name:    "project add",
			command: "project",
			pos:     []string{"add"},
			opts: map[string]string{
				"name":           "demo",
				"path":           "/tmp/demo",
				"url":            "file:///tmp/demo",
				"default_branch": "main",
			},
			wantOp: "project.add",
			want: map[string]any{
				"name":            "demo",
				"repository_path": "/tmp/demo",
				"repository_url":  "file:///tmp/demo",
				"default_branch":  "main",
			},
		},
		{
			name:    "mission create",
			command: "mission",
			pos:     []string{"create"},
			opts: map[string]string{
				"project":    "project-1",
				"objective":  "objective",
				"scope":      "scope",
				"acceptance": "criteria",
			},
			wantOp: "mission.create",
			want: map[string]any{
				"project_id":          "project-1",
				"objective":           "objective",
				"scope":               "scope",
				"acceptance_criteria": "criteria",
			},
		},
		{
			name:    "mission submit",
			command: "mission",
			pos:     []string{"submit", "mission-1"},
			wantOp:  "mission.submit",
			want:    map[string]any{"mission_id": "mission-1"},
		},
		{
			name:    "mission request changes",
			command: "mission",
			pos:     []string{"request-changes", "mission-1"},
			opts:    map[string]string{"reason": "needs detail"},
			wantOp:  "mission.request_changes",
			want:    map[string]any{"mission_id": "mission-1", "reason": "needs detail"},
		},
		{
			name:    "mission authorize",
			command: "mission",
			pos:     []string{"authorize", "mission-1"},
			wantOp:  "mission.grant_work",
			want:    map[string]any{"mission_id": "mission-1"},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			gotOp, got, err := mapCommand(test.command, test.pos, test.opts)
			if err != nil {
				t.Fatal(err)
			}
			if gotOp != test.wantOp {
				t.Fatalf("op=%q want %q", gotOp, test.wantOp)
			}
			for key, want := range test.want {
				if got[key] != want {
					t.Fatalf("payload[%q]=%v want %v", key, got[key], want)
				}
			}
		})
	}
}

func TestWorkflowAuthorizationUsesBossSocketAndStableConfirmation(t *testing.T) {
	var seen []map[string]any
	home, _ := serve(t, func(req map[string]any) map[string]any {
		seen = append(seen, req)
		switch req["op"] {
		case "mission.get":
			return map[string]any{
				"v": req["v"], "id": req["id"], "ok": true,
				"payload": map[string]any{
					"id": "mission-1", "project_id": "project-1", "objective": "objective",
					"scope": "scope", "acceptance_criteria": "criteria", "base_sha": "sha-1",
					"phase": "awaiting_authorization",
				},
			}
		case "mission.grant_work":
			return map[string]any{
				"v": req["v"], "id": req["id"], "ok": true,
				"payload": map[string]any{
					"id": "mission-1", "phase": "authorized", "authorization_id": "auth-1",
				},
			}
		default:
			return map[string]any{"v": req["v"], "id": req["id"], "ok": true, "payload": map[string]any{}}
		}
	})
	t.Setenv("CS_HOME", home.Dir)

	var out, errb bytes.Buffer
	code := Run([]string{
		"mission", "authorize", "mission-1", "--yes", "--idempotency-key", "auth-key", "--json",
	}, &out, &errb)
	if code != ExitOK {
		t.Fatalf("exit %d stderr=%s", code, errb.String())
	}
	if !strings.Contains(out.String(), `"authorization_id":"auth-1"`) {
		t.Fatalf("out=%q", out.String())
	}
	if len(seen) != 2 {
		t.Fatalf("requests=%d", len(seen))
	}
	for _, req := range seen {
		if req["secret"] != "secret" {
			t.Fatalf("request did not use boss credential: %#v", req)
		}
	}
	if seen[1]["idempotency_key"] != "auth-key" {
		t.Fatalf("key=%v", seen[1]["idempotency_key"])
	}
}

func TestWorkflowConfirmationDisplaysMissionIdentityBeforeMutation(t *testing.T) {
	home, _ := serve(t, func(req map[string]any) map[string]any {
		if req["op"] == "mission.get" {
			return map[string]any{
				"v": req["v"], "id": req["id"], "ok": true,
				"payload": map[string]any{
					"id": "mission-1", "project_id": "project-1", "objective": "objective",
					"scope": "scope", "acceptance_criteria": "criteria", "base_sha": "sha-1",
					"phase": "awaiting_authorization",
				},
			}
		}
		return map[string]any{
			"v": req["v"], "id": req["id"], "ok": true,
			"payload": map[string]any{
				"id": "mission-1", "phase": "authorized", "authorization_id": "auth-1",
			},
		}
	})
	t.Setenv("CS_HOME", home.Dir)

	var out, errb bytes.Buffer
	code := runWithInput([]string{"mission", "authorize", "mission-1", "--idempotency-key", "auth-key"}, &out, &errb, bytes.NewBufferString("yes\n"))
	if code != ExitOK {
		t.Fatalf("exit %d stderr=%s", code, errb.String())
	}
	for _, want := range []string{
		"Project: project-1",
		"Mission ID: mission-1",
		"Objective: objective",
		"Scope: scope",
		"Acceptance criteria: criteria",
		"Immutable base SHA: sha-1",
		"Confirm [y/N]:",
	} {
		if !strings.Contains(out.String(), want) {
			t.Fatalf("confirmation missing %q in %q", want, out.String())
		}
	}
}

func TestDoctorAbsentJSON(t *testing.T) {
	dir := shortDir(t)
	t.Setenv("CS_HOME", dir)
	var out, errb strings.Builder
	code := Run([]string{"--json", "doctor"}, &out, &errb)
	if code != ExitAbsent {
		t.Fatalf("exit %d", code)
	}
	if !strings.Contains(out.String(), `"boss_socket":"absent"`) {
		t.Fatalf("out=%q", out.String())
	}
	if strings.Contains(out.String(), "consigliere.db") && strings.Contains(strings.ToLower(out.String()), "open ") {
		t.Fatal("doctor must not claim to open sqlite")
	}
}

func TestDoctorReportsMalformedOwnerMetadata(t *testing.T) {
	dir := shortDir(t)
	t.Setenv("CS_HOME", dir)
	if err := os.WriteFile(filepath.Join(dir, "owner.json"), []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}

	var out, errb strings.Builder
	_ = Run([]string{"--json", "doctor"}, &out, &errb)
	if !strings.Contains(out.String(), `"owner":"malformed"`) {
		t.Fatalf("out=%q stderr=%q", out.String(), errb.String())
	}
}

func TestCallRetriesMutatingRequestWithOneGeneratedKey(t *testing.T) {
	dir := shortDir(t)
	home := Home{Dir: dir}
	if err := os.MkdirAll(filepath.Join(dir, "credentials"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(home.CredentialPath(), []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}

	ln, err := net.Listen("unix", home.PrivilegedSocket())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ln.Close() })

	keys := make(chan string, 2)
	var requests atomic.Int32
	go func() {
		for {
			conn, acceptErr := ln.Accept()
			if acceptErr != nil {
				return
			}
			line, readErr := bufio.NewReader(conn).ReadBytes('\n')
			if readErr != nil && len(line) == 0 {
				_ = conn.Close()
				continue
			}
			var req map[string]any
			if json.Unmarshal(line, &req) != nil {
				_ = conn.Close()
				continue
			}
			key, _ := req["idempotency_key"].(string)
			keys <- key
			if requests.Add(1) == 1 {
				_ = conn.Close()
				continue
			}
			response := map[string]any{
				"v":       1,
				"id":      req["id"],
				"ok":      true,
				"payload": map[string]any{"id": "mission-1"},
			}
			body, _ := json.Marshal(response)
			_, _ = conn.Write(append(body, '\n'))
			_ = conn.Close()
		}
	}()

	d := NewBossDialer(home)
	d.ReadTimeout = 2 * time.Second
	resp, err := d.Call("mission.create", map[string]any{
		"project_id":          "project-1",
		"objective":           "objective",
		"scope":               "scope",
		"acceptance_criteria": "criteria",
	}, "correlation-1", "")
	if err != nil {
		t.Fatalf("call: %v", err)
	}
	if resp == nil || !resp.OK {
		t.Fatalf("response: %#v", resp)
	}
	firstKey := <-keys
	secondKey := <-keys
	if firstKey == "" || firstKey != secondKey {
		t.Fatalf("keys=%q,%q", firstKey, secondKey)
	}
}

func TestVersionWithoutDaemon(t *testing.T) {
	dir := shortDir(t)
	t.Setenv("CS_HOME", dir)
	var out, errb strings.Builder
	code := Run([]string{"version"}, &out, &errb)
	if code != ExitOK {
		t.Fatalf("exit %d", code)
	}
	if !strings.Contains(out.String(), "cs 0.1.0") {
		t.Fatalf("out=%q", out.String())
	}
}

func TestConcurrentPings(t *testing.T) {
	var n atomic.Int32
	home, _ := serve(t, func(req map[string]any) map[string]any {
		n.Add(1)
		return map[string]any{"v": 1, "id": req["id"], "ok": true, "payload": map[string]any{"pong": true}}
	})
	t.Setenv("CS_HOME", home.Dir)
	done := make(chan int, 4)
	for i := 0; i < 4; i++ {
		go func() {
			var out, errb strings.Builder
			done <- Run([]string{"ping"}, &out, &errb)
		}()
	}
	for i := 0; i < 4; i++ {
		if code := <-done; code != ExitOK {
			t.Fatalf("exit %d", code)
		}
	}
	if n.Load() != 4 {
		t.Fatalf("handled %d pings", n.Load())
	}
}

func TestIdempotencyKeyForwarded(t *testing.T) {
	var got string
	home, _ := serve(t, func(req map[string]any) map[string]any {
		got, _ = req["idempotency_key"].(string)
		return map[string]any{"v": 1, "id": req["id"], "ok": true, "payload": map[string]any{"away": true}}
	})
	t.Setenv("CS_HOME", home.Dir)
	var out, errb strings.Builder
	code := Run([]string{"away", "--idempotency-key", "k1"}, &out, &errb)
	if code != ExitOK {
		t.Fatalf("exit %d stderr=%s", code, errb.String())
	}
	if got != "k1" {
		t.Fatalf("idempotency_key=%q", got)
	}
}
