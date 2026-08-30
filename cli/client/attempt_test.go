package client

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"strings"
	"testing"
)

func TestRunAttemptCompleteUsesBoundCapabilityAndLatestTerminalSequence(t *testing.T) {
	const (
		attemptID           = "attempt-1"
		missionID           = "mission-1"
		projectID           = "project-1"
		workspaceID         = "workspace-1"
		workspaceGeneration = "workspace-generation-1"
		fencingGeneration   = "fence-1"
		baseSHA             = "0123456789012345678901234567890123456789"
		resultSHA           = "fedcba9876543210fedcba9876543210fedcba98"
		capabilityID        = "capability-1"
	)

	var seen map[string]any
	home, _ := serve(t, func(req map[string]any) map[string]any {
		seen = req
		return map[string]any{
			"v": req["v"], "id": req["id"], "ok": true,
			"payload": map[string]any{"status": "completion_reported"},
		}
	})

	t.Setenv("CS_API_SOCKET", home.APISocket())
	t.Setenv("CS_CAPABILITY", "capability-secret")
	t.Setenv("CS_ATTEMPT_ID", attemptID)
	t.Setenv("CS_MISSION_ID", missionID)
	t.Setenv("CS_PROJECT_ID", projectID)
	t.Setenv("CS_WORKSPACE_ID", workspaceID)
	t.Setenv("CS_WORKSPACE_GENERATION", workspaceGeneration)
	t.Setenv("CS_BASE_SHA", baseSHA)
	t.Setenv("CS_FENCING_GENERATION", fencingGeneration)
	t.Setenv("CS_CAPABILITY_ID", capabilityID)
	t.Setenv("CS_CAPABILITY_GENERATION", "7")

	var out, errOut bytes.Buffer
	code := RunAttempt([]string{"complete", "--sha", resultSHA}, &out, &errOut)
	if code != ExitOK {
		t.Fatalf("exit=%d stdout=%q stderr=%q", code, out.String(), errOut.String())
	}
	if strings.Contains(out.String()+errOut.String(), "capability-secret") {
		t.Fatalf("capability leaked in output: %q %q", out.String(), errOut.String())
	}

	if seen["op"] != "attempt.complete" {
		t.Fatalf("op=%v", seen["op"])
	}
	if seen["secret"] != "capability-secret" {
		t.Fatalf("secret=%v", seen["secret"])
	}
	actor := seen["actor"].(map[string]any)
	if actor["principal"] != "attempt" {
		t.Fatalf("actor=%v", actor)
	}
	payload := seen["payload"].(map[string]any)
	wantPayload := map[string]any{
		"attempt_id":           attemptID,
		"mission_id":           missionID,
		"project_id":           projectID,
		"workspace_id":         workspaceID,
		"workspace_generation": workspaceGeneration,
		"base_sha":             baseSHA,
		"fencing_generation":   fencingGeneration,
		"result_sha":           resultSHA,
		"result_kind":          "completed",
		"terminal_sequence":    "latest",
	}
	for key, want := range wantPayload {
		if payload[key] != want {
			t.Fatalf("payload[%q]=%v want %v", key, payload[key], want)
		}
	}

	key, ok := seen["idempotency_key"].(string)
	if !ok || key == "" {
		t.Fatalf("missing idempotency key: %v", seen["idempotency_key"])
	}
	gotHash, ok := seen["canonical_hash"].(string)
	if !ok || gotHash == "" {
		t.Fatalf("missing canonical hash: %v", seen["canonical_hash"])
	}
	scope := "attempt:" + attemptID + ":" + fencingGeneration + ":capability:" + capabilityID + ":7"
	wantHash, err := CanonicalRequestHash(scope, "attempt.complete", 1, key, payload)
	if err != nil {
		t.Fatal(err)
	}
	if gotHash != wantHash {
		t.Fatalf("canonical_hash=%s want %s", gotHash, wantHash)
	}

	var response map[string]any
	if err := json.Unmarshal(out.Bytes(), &response); err != nil {
		t.Fatalf("response: %v", err)
	}
	if response["ok"] != true {
		t.Fatalf("response=%v", response)
	}
}

func TestRunAttemptRejectsMissingBoundIdentity(t *testing.T) {
	for _, key := range []string{
		"CS_API_SOCKET",
		"CS_CAPABILITY",
		"CS_ATTEMPT_ID",
		"CS_MISSION_ID",
		"CS_PROJECT_ID",
		"CS_WORKSPACE_ID",
		"CS_WORKSPACE_GENERATION",
		"CS_BASE_SHA",
		"CS_FENCING_GENERATION",
		"CS_CAPABILITY_ID",
		"CS_CAPABILITY_GENERATION",
	} {
		t.Run(key, func(t *testing.T) {
			for _, env := range []string{
				"CS_API_SOCKET", "CS_CAPABILITY", "CS_ATTEMPT_ID", "CS_MISSION_ID",
				"CS_PROJECT_ID", "CS_WORKSPACE_ID", "CS_WORKSPACE_GENERATION", "CS_BASE_SHA",
				"CS_FENCING_GENERATION", "CS_CAPABILITY_ID", "CS_CAPABILITY_GENERATION",
			} {
				t.Setenv(env, "bound")
			}
			t.Setenv(key, "")

			var out, errOut bytes.Buffer
			if code := RunAttempt([]string{"complete", "--sha", strings.Repeat("a", 40)}, &out, &errOut); code != ExitUsage {
				t.Fatalf("exit=%d stdout=%q stderr=%q", code, out.String(), errOut.String())
			}
		})
	}
}

func TestRunAttemptBridgeEmitsBoundReportWithoutSocketAccess(t *testing.T) {
	const resultSHA = "fedcba9876543210fedcba9876543210fedcba98"
	for key, value := range map[string]string{
		"CS_ATTEMPT_ID":            "attempt-1",
		"CS_MISSION_ID":            "mission-1",
		"CS_PROJECT_ID":            "project-1",
		"CS_WORKSPACE_ID":          "workspace-1",
		"CS_WORKSPACE_GENERATION":  "workspace-generation-1",
		"CS_BASE_SHA":              "0123456789012345678901234567890123456789",
		"CS_FENCING_GENERATION":    "fence-1",
		"CS_CAPABILITY_ID":         "capability-1",
		"CS_CAPABILITY_GENERATION": "7",
		"CS_ATTEMPT_BRIDGE":        "1",
	} {
		t.Setenv(key, value)
	}

	var out, errOut bytes.Buffer
	if code := RunAttempt([]string{"complete", "--sha", resultSHA}, &out, &errOut); code != ExitOK {
		t.Fatalf("exit=%d stdout=%q stderr=%q", code, out.String(), errOut.String())
	}
	if strings.Contains(out.String()+errOut.String(), "capability-secret") {
		t.Fatalf("capability leaked in bridge output: %q %q", out.String(), errOut.String())
	}
	line := strings.TrimSpace(out.String())
	const prefix = "CS_ATTEMPT_REPORT_V1:"
	if !strings.HasPrefix(line, prefix) {
		t.Fatalf("marker=%q", line)
	}
	decoded, err := hex.DecodeString(strings.TrimPrefix(line, prefix))
	if err != nil {
		t.Fatalf("marker hex: %v", err)
	}
	var report struct {
		Operation string         `json:"operation"`
		Payload   map[string]any `json:"payload"`
	}
	if err := json.Unmarshal(decoded, &report); err != nil {
		t.Fatalf("marker json: %v", err)
	}
	if report.Operation != "complete" || report.Payload["result_sha"] != resultSHA {
		t.Fatalf("report=%v", report)
	}
}
