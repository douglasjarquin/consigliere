package client

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
)

func RunAttempt(args []string, stdout, stderr io.Writer) int {
	operation, resultSHA, err := parseAttemptArgs(args)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return ExitUsage
	}

	identity, err := attemptIdentityFromEnv()
	if err != nil {
		fmt.Fprintln(stderr, err)
		return ExitUsage
	}

	resultKind := "checkpoint"
	if operation == "complete" {
		resultKind = "completed"
	}
	payload := map[string]any{
		"attempt_id":           identity.attemptID,
		"mission_id":           identity.missionID,
		"project_id":           identity.projectID,
		"workspace_id":         identity.workspaceID,
		"workspace_generation": identity.workspaceGeneration,
		"base_sha":             identity.baseSHA,
		"fencing_generation":   identity.fencingGeneration,
		"result_sha":           resultSHA,
		"result_kind":          resultKind,
		"terminal_sequence":    "latest",
	}
	if identity.parentCheckpointSHA != "" {
		payload["parent_checkpoint_sha"] = identity.parentCheckpointSHA
	}

	op := "attempt." + operation
	idem := "attempt:" + identity.attemptID + ":" + operation
	dialer := NewAttemptDialer(identity.socket, identity.capability, identity.authorityScope())
	response, callErr := dialer.Call(op, payload, idem, idem)
	if response != nil {
		encoder := json.NewEncoder(stdout)
		encoder.SetEscapeHTML(false)
		_ = encoder.Encode(response)
	}
	if callErr != nil {
		PrintError(stderr, callErr, response)
		return ExitFor(callErr, response)
	}
	if response == nil || !response.OK {
		PrintError(stderr, nil, response)
		return ExitError
	}
	return ExitOK
}

type attemptIdentity struct {
	socket               string
	capability           string
	attemptID            string
	missionID            string
	projectID            string
	workspaceID          string
	workspaceGeneration  string
	baseSHA              string
	parentCheckpointSHA  string
	fencingGeneration    string
	capabilityID         string
	capabilityGeneration int
}

func (i attemptIdentity) authorityScope() string {
	return fmt.Sprintf("attempt:%s:%s:capability:%s:%d", i.attemptID, i.fencingGeneration, i.capabilityID, i.capabilityGeneration)
}

func parseAttemptArgs(args []string) (string, string, error) {
	if len(args) != 3 || (args[0] != "complete" && args[0] != "checkpoint") || args[1] != "--sha" {
		return "", "", errors.New("usage: cs-attempt <complete|checkpoint> --sha FULL_GIT_SHA")
	}
	if !validFullSHA(args[2]) {
		return "", "", errors.New("result SHA must be a full 40-character Git SHA")
	}
	return args[0], strings.ToLower(args[2]), nil
}

func attemptIdentityFromEnv() (attemptIdentity, error) {
	get := func(name string) (string, error) {
		value := strings.TrimSpace(os.Getenv(name))
		if value == "" {
			return "", fmt.Errorf("required bound identity %s is missing", name)
		}
		return value, nil
	}

	var identity attemptIdentity
	var err error
	if identity.socket, err = get("CS_API_SOCKET"); err != nil {
		return attemptIdentity{}, err
	}
	if identity.capability, err = get("CS_CAPABILITY"); err != nil {
		return attemptIdentity{}, err
	}
	if identity.attemptID, err = get("CS_ATTEMPT_ID"); err != nil {
		return attemptIdentity{}, err
	}
	if identity.missionID, err = get("CS_MISSION_ID"); err != nil {
		return attemptIdentity{}, err
	}
	if identity.projectID, err = get("CS_PROJECT_ID"); err != nil {
		return attemptIdentity{}, err
	}
	if identity.workspaceID, err = get("CS_WORKSPACE_ID"); err != nil {
		return attemptIdentity{}, err
	}
	if identity.workspaceGeneration, err = get("CS_WORKSPACE_GENERATION"); err != nil {
		return attemptIdentity{}, err
	}
	if identity.baseSHA, err = get("CS_BASE_SHA"); err != nil {
		return attemptIdentity{}, err
	}
	if !validFullSHA(identity.baseSHA) {
		return attemptIdentity{}, errors.New("bound base SHA must be a full 40-character Git SHA")
	}
	if identity.fencingGeneration, err = get("CS_FENCING_GENERATION"); err != nil {
		return attemptIdentity{}, err
	}
	if identity.capabilityID, err = get("CS_CAPABILITY_ID"); err != nil {
		return attemptIdentity{}, err
	}
	generation, err := get("CS_CAPABILITY_GENERATION")
	if err != nil {
		return attemptIdentity{}, err
	}
	identity.capabilityGeneration, err = strconv.Atoi(generation)
	if err != nil || identity.capabilityGeneration < 1 {
		return attemptIdentity{}, errors.New("bound capability generation must be positive")
	}
	identity.parentCheckpointSHA = strings.TrimSpace(os.Getenv("CS_PARENT_CHECKPOINT_SHA"))
	if identity.parentCheckpointSHA != "" && !validFullSHA(identity.parentCheckpointSHA) {
		return attemptIdentity{}, errors.New("bound parent checkpoint SHA must be a full 40-character Git SHA")
	}
	return identity, nil
}

func validFullSHA(value string) bool {
	if len(value) != 40 {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}
