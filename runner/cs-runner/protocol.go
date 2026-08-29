package main

import (
	"bufio"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
)

const (
	controlProtocolVersion = 1
	maxBootstrapBytes      = v0FrameBytes
	maxHandshakeFrameBytes = v0FrameBytes
)

type InvocationIdentity struct {
	ProtocolVersion     int    `json:"protocol_version"`
	InvocationID        string `json:"invocation_id"`
	AttemptID           string `json:"attempt_id"`
	MissionID           string `json:"mission_id"`
	WorkspacePath       string `json:"workspace_path"`
	WorkspaceGeneration string `json:"workspace_generation"`
	FencingGeneration   string `json:"fencing_generation"`
}

type RunnerIdentity struct {
	InvocationIdentity
	RunnerPID               int    `json:"runner_pid"`
	PGID                    int    `json:"pgid"`
	ManifestDigest          string `json:"manifest_digest"`
	RunnerExecutableSHA256  string `json:"runner_executable_sha256"`
	HarnessExecutableSHA256 string `json:"harness_executable_sha256"`
}

type Bootstrap struct {
	SecretHex                      string             `json:"secret_hex"`
	Identity                       InvocationIdentity `json:"identity"`
	ExpectedRunnerExecutableSHA256 string             `json:"expected_runner_executable_sha256"`
	CloseStdin                     bool               `json:"-"`
}

func (b Bootstrap) secret() ([]byte, error) {
	secret, err := hex.DecodeString(b.SecretHex)
	if err != nil || len(secret) != sha256.Size {
		return nil, errors.New("bootstrap secret must be 32 random bytes encoded as hex")
	}
	return secret, nil
}

func (i InvocationIdentity) validate() error {
	if i.ProtocolVersion != controlProtocolVersion {
		return fmt.Errorf("unsupported control protocol version %d", i.ProtocolVersion)
	}
	for name, value := range map[string]string{
		"invocation_id":        i.InvocationID,
		"attempt_id":           i.AttemptID,
		"mission_id":           i.MissionID,
		"workspace_path":       i.WorkspacePath,
		"workspace_generation": i.WorkspaceGeneration,
		"fencing_generation":   i.FencingGeneration,
	} {
		if value == "" {
			return fmt.Errorf("%s must not be empty", name)
		}
	}
	return nil
}

func (i InvocationIdentity) equal(other InvocationIdentity) bool {
	return i == other
}

func (r RunnerIdentity) equal(other RunnerIdentity) bool {
	return r.InvocationIdentity.equal(other.InvocationIdentity) &&
		r.RunnerPID == other.RunnerPID &&
		r.PGID == other.PGID &&
		r.ManifestDigest == other.ManifestDigest &&
		r.RunnerExecutableSHA256 == other.RunnerExecutableSHA256 &&
		r.HarnessExecutableSHA256 == other.HarnessExecutableSHA256
}

func identityFields(identity InvocationIdentity) map[string]any {
	return map[string]any{
		"protocol_version":     identity.ProtocolVersion,
		"invocation_id":        identity.InvocationID,
		"attempt_id":           identity.AttemptID,
		"mission_id":           identity.MissionID,
		"workspace_path":       identity.WorkspacePath,
		"workspace_generation": identity.WorkspaceGeneration,
		"fencing_generation":   identity.FencingGeneration,
	}
}

func runnerFields(runner RunnerIdentity) map[string]any {
	fields := identityFields(runner.InvocationIdentity)
	fields["runner_pid"] = runner.RunnerPID
	fields["pgid"] = runner.PGID
	fields["manifest_digest"] = runner.ManifestDigest
	fields["runner_executable_sha256"] = runner.RunnerExecutableSHA256
	fields["harness_executable_sha256"] = runner.HarnessExecutableSHA256
	return fields
}

func handshakeMessage(kind string, identity InvocationIdentity, runner RunnerIdentity, daemonNonce, runnerNonce string, secret []byte) map[string]any {
	message := runnerFields(runner)
	message["type"] = kind
	message["daemon_nonce"] = daemonNonce
	message["runner_nonce"] = runnerNonce
	message["mac"] = messageMAC(message, secret)
	return message
}

func frameMessage(identity InvocationIdentity, seq uint64, message map[string]any, secret []byte) map[string]any {
	frame := make(map[string]any, len(message)+10)
	for key, value := range message {
		frame[key] = value
	}
	for key, value := range identityFields(identity) {
		frame[key] = value
	}
	frame["fencing_token"] = identity.FencingGeneration
	frame["seq"] = seq
	frame["mac"] = messageMAC(frame, secret)
	return frame
}

func messageMAC(message map[string]any, secret []byte) string {
	unsigned := make(map[string]any, len(message))
	for key, value := range message {
		if key != "mac" {
			unsigned[key] = value
		}
	}
	encoded, err := canonicalJSON(unsigned)
	if err != nil {
		return ""
	}
	h := hmac.New(sha256.New, secret)
	_, _ = h.Write(encoded)
	return hex.EncodeToString(h.Sum(nil))
}

func canonicalJSON(value any) ([]byte, error) {
	var output []byte
	encoder := json.NewEncoder(&byteBuffer{target: &output})
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return nil, err
	}
	if len(output) > 0 && output[len(output)-1] == '\n' {
		output = output[:len(output)-1]
	}
	return output, nil
}

type byteBuffer struct {
	target *[]byte
}

func (b *byteBuffer) Write(p []byte) (int, error) {
	*b.target = append(*b.target, p...)
	return len(p), nil
}

func decodeHandshakeIdentity(message map[string]any) (InvocationIdentity, error) {
	protocol, err := intField(message, "protocol_version")
	if err != nil {
		return InvocationIdentity{}, err
	}
	identity := InvocationIdentity{
		ProtocolVersion:     protocol,
		InvocationID:        stringField(message, "invocation_id"),
		AttemptID:           stringField(message, "attempt_id"),
		MissionID:           stringField(message, "mission_id"),
		WorkspacePath:       stringField(message, "workspace_path"),
		WorkspaceGeneration: stringField(message, "workspace_generation"),
		FencingGeneration:   stringField(message, "fencing_generation"),
	}
	if err := identity.validate(); err != nil {
		return InvocationIdentity{}, err
	}
	return identity, nil
}

func decodeRunnerIdentity(message map[string]any) (RunnerIdentity, error) {
	identity, err := decodeHandshakeIdentity(message)
	if err != nil {
		return RunnerIdentity{}, err
	}
	runnerPID, err := intField(message, "runner_pid")
	if err != nil {
		return RunnerIdentity{}, err
	}
	pgid, err := intField(message, "pgid")
	if err != nil {
		return RunnerIdentity{}, err
	}
	if runnerPID <= 1 || pgid <= 1 {
		return RunnerIdentity{}, errors.New("runner PID and PGID must be non-degenerate")
	}
	runner := RunnerIdentity{
		InvocationIdentity:      identity,
		RunnerPID:               runnerPID,
		PGID:                    pgid,
		ManifestDigest:          stringField(message, "manifest_digest"),
		RunnerExecutableSHA256:  stringField(message, "runner_executable_sha256"),
		HarnessExecutableSHA256: stringField(message, "harness_executable_sha256"),
	}
	if runner.ManifestDigest == "" || runner.RunnerExecutableSHA256 == "" {
		return RunnerIdentity{}, errors.New("runner handshake is missing manifest or executable identity")
	}
	return runner, nil
}

func stringField(message map[string]any, name string) string {
	value, _ := message[name].(string)
	return value
}

func intField(message map[string]any, name string) (int, error) {
	value, ok := message[name].(float64)
	if !ok || value != float64(int(value)) {
		return 0, fmt.Errorf("%s must be an integer", name)
	}
	return int(value), nil
}

func sequenceField(message map[string]any) (uint64, error) {
	value, ok := message["seq"].(float64)
	if !ok || value < 1 || value != float64(uint64(value)) {
		return 0, errors.New("seq must be a positive integer")
	}
	return uint64(value), nil
}

func verifyMAC(message map[string]any, secret []byte) error {
	provided, ok := message["mac"].(string)
	if !ok {
		return errors.New("missing frame MAC")
	}
	want := messageMAC(message, secret)
	providedBytes, err := hex.DecodeString(provided)
	if err != nil || len(providedBytes) != sha256.Size {
		return errors.New("invalid frame MAC")
	}
	wantBytes, err := hex.DecodeString(want)
	if err != nil || !hmac.Equal(providedBytes, wantBytes) {
		return errors.New("frame MAC mismatch")
	}
	return nil
}

func readBootstrapFromStdin() (Bootstrap, error) {
	line, err := readBoundedLine(bufio.NewReaderSize(os.Stdin, 4096), maxBootstrapBytes)
	if err != nil {
		return Bootstrap{}, fmt.Errorf("read private runner bootstrap: %w", err)
	}
	var bootstrap Bootstrap
	if err := json.Unmarshal([]byte(line), &bootstrap); err != nil {
		return Bootstrap{}, fmt.Errorf("decode private runner bootstrap: %w", err)
	}
	if _, err := bootstrap.secret(); err != nil {
		return Bootstrap{}, err
	}
	if err := bootstrap.Identity.validate(); err != nil {
		return Bootstrap{}, err
	}
	return bootstrap, nil
}

func manifestFileDigest(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:]), nil
}

func validateBootstrapIdentity(bootstrap Bootstrap, flagIdentity InvocationIdentity) error {
	if err := flagIdentity.validate(); err != nil {
		return err
	}
	if !bootstrap.Identity.equal(flagIdentity) {
		return errors.New("bootstrap identity does not match runner arguments")
	}
	return nil
}

func randomNonce() string {
	value := make([]byte, 32)
	if _, err := rand.Read(value); err != nil {
		panic(err)
	}
	return hex.EncodeToString(value)
}
