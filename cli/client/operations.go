package client

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"sync/atomic"
	"time"
	"unicode/utf8"
)

var v0Operations = map[string]int{
	"project.add":               1,
	"mission.create":            1,
	"mission.submit":            1,
	"mission.request_changes":   1,
	"mission.grant_work":        1,
	"mission.continue":          1,
	"mission.cancel":            1,
	"mission.pause":             1,
	"mission.resume":            1,
	"mission.grant_integration": 1,
	"question.open":             1,
	"question.answer":           1,
	"away.mark":                 1,
	"away.return":               1,
	"attempt.progress":          1,
	"attempt.checkpoint":        1,
	"attempt.completion":        1,
	"attempt.failure":           1,
	"internal.dispatch":         1,
	"post_attempt.progress":     1,
}

func operationVersion(op string) (int, bool) {
	version, ok := v0Operations[op]
	return version, ok
}

func CanonicalRequestHash(scope, op string, version int, key string, payload map[string]any) (string, error) {
	if scope == "" || op == "" || version <= 0 || key == "" {
		return "", fmt.Errorf("canonical request identity is incomplete")
	}
	canonical, err := canonicalJSON(map[string]any{
		"authority_scope": scope,
		"idempotency_key": key,
		"operation": map[string]any{
			"name":    op,
			"version": version,
		},
		"payload": payload,
	})
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(canonical)
	return hex.EncodeToString(sum[:]), nil
}

func canonicalJSON(value any) ([]byte, error) {
	if err := validateCanonicalValue(value, 0); err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	encoder := json.NewEncoder(&buf)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte{'\n'}), nil
}

func validateCanonicalValue(value any, depth int) error {
	if depth > 8 {
		return fmt.Errorf("canonical payload is too deep")
	}
	switch value := value.(type) {
	case nil, bool:
		return nil
	case string:
		if !utf8.ValidString(value) {
			return fmt.Errorf("canonical payload is not UTF-8")
		}
		if len(value) > 8192 {
			return fmt.Errorf("canonical payload string is too long")
		}
		return nil
	case int, int8, int16, int32, int64, uint, uint8, uint16, uint32, uint64:
		return nil
	case float32, float64:
		return fmt.Errorf("canonical payload does not permit floating values")
	case map[string]any:
		if len(value) > 128 {
			return fmt.Errorf("canonical payload has too many fields")
		}
		for key, nested := range value {
			if !utf8.ValidString(key) || len(key) > 256 {
				return fmt.Errorf("canonical payload key is invalid")
			}
			if err := validateCanonicalValue(nested, depth+1); err != nil {
				return err
			}
		}
		return nil
	case []any:
		if len(value) > 128 {
			return fmt.Errorf("canonical payload list is too long")
		}
		for _, nested := range value {
			if err := validateCanonicalValue(nested, depth+1); err != nil {
				return err
			}
		}
		return nil
	default:
		return fmt.Errorf("canonical payload contains unsupported value %T", value)
	}
}

var generatedKeySequence atomic.Uint64

func generatedIdempotencyKey() string {
	var random [16]byte
	if _, err := rand.Read(random[:]); err == nil {
		return "cs-" + hex.EncodeToString(random[:])
	}
	sequence := generatedKeySequence.Add(1)
	return fmt.Sprintf("cs-%d-%d", time.Now().UnixNano(), sequence)
}

func boundedRetryDelay() {
	time.Sleep(25 * time.Millisecond)
}

func isMutatingOperation(op string) bool {
	_, ok := operationVersion(op)
	return ok
}

func canonicalScope(principal string) string {
	return strings.TrimSpace(principal)
}
