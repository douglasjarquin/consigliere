package client

import (
	"testing"
)

func TestCanonicalJSONUsesSortedCompactUTF8Objects(t *testing.T) {
	got, err := canonicalJSON(map[string]any{
		"payload": map[string]any{
			"z":                   2,
			"acceptance_criteria": "criteria",
			"objective":           "objective",
			"project_id":          "project-1",
			"scope":               "scope",
		},
		"operation": map[string]any{
			"version": 1,
			"name":    "mission.create",
		},
		"idempotency_key": "key-1",
		"authority_scope": "boss",
	})
	if err != nil {
		t.Fatal(err)
	}

	want := []byte("{\"authority_scope\":\"boss\",\"idempotency_key\":\"key-1\",\"operation\":{\"name\":\"mission.create\",\"version\":1},\"payload\":{\"acceptance_criteria\":\"criteria\",\"objective\":\"objective\",\"project_id\":\"project-1\",\"scope\":\"scope\",\"z\":2}}")
	if string(got) != string(want) {
		t.Fatalf("canonical=%s want=%s", got, want)
	}
}
