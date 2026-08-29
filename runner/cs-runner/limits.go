package main

import (
	"bytes"
	"encoding/hex"
	"errors"
	"fmt"
	"unicode/utf8"
)

const (
	v0FrameBytes      = 1_048_576
	v0JSONDepth       = 64
	v0CollectionItems = 256
	v0StringBytes     = 65_536
	v0SemanticBytes   = 65_536
	v0FinalTextBytes  = 4_096
	v0UsageRows       = 4_096
	v0UsageBytes      = 1_048_576
)

var (
	errFrameTooLarge      = errors.New("frame exceeds V0 size limit")
	errJSONDepth          = errors.New("JSON nesting exceeds V0 limit")
	errCollectionTooLarge = errors.New("JSON collection exceeds V0 limit")
	errStringTooLarge     = errors.New("JSON string exceeds V0 limit")
	errUnsafeControl      = errors.New("unsafe ANSI or OSC control sequence")
	errInvalidUTF8        = errors.New("JSON is not valid UTF-8")
	errMalformedJSON      = errors.New("malformed JSON")
)

type jsonContainer struct {
	kind   byte
	commas int
}

func validateV0JSONFrame(frame []byte) error {
	if len(frame) > v0FrameBytes {
		return errFrameTooLarge
	}
	if !utf8.Valid(frame) {
		return errInvalidUTF8
	}

	trimmed := bytes.TrimSpace(frame)
	stack := make([]jsonContainer, 0, 8)
	for index := 0; index < len(trimmed); {
		b := trimmed[index]
		switch {
		case b == ' ' || b == '\t' || b == '\r' || b == '\n':
			index++
		case b == '"':
			next, err := scanJSONString(trimmed, index+1)
			if err != nil {
				return err
			}
			index = next
		case b == '{' || b == '[':
			if len(stack) >= v0JSONDepth {
				return errJSONDepth
			}
			stack = append(stack, jsonContainer{kind: b})
			index++
		case b == '}' || b == ']':
			if len(stack) == 0 || !matchingContainer(stack[len(stack)-1].kind, b) {
				return errMalformedJSON
			}
			stack = stack[:len(stack)-1]
			index++
		case b == ',':
			if len(stack) == 0 {
				return errMalformedJSON
			}
			container := &stack[len(stack)-1]
			if container.commas >= v0CollectionItems-1 {
				return errCollectionTooLarge
			}
			container.commas++
			index++
		case b < 0x20:
			return errMalformedJSON
		case b == 0x9d:
			return errUnsafeControl
		default:
			index++
		}
	}

	if len(stack) != 0 {
		return errMalformedJSON
	}
	return nil
}

func scanJSONString(value []byte, index int) (int, error) {
	bytesSeen := 0
	for index < len(value) {
		b := value[index]
		switch {
		case b == '"':
			return index + 1, nil
		case b == '\\':
			if index+1 >= len(value) {
				return 0, errMalformedJSON
			}
			escaped := value[index+1]
			if escaped == 'u' {
				if index+5 >= len(value) || !isHex(value[index+2:index+6]) {
					return 0, errMalformedJSON
				}
				if bytes.EqualFold(value[index+2:index+6], []byte("001b")) {
					return 0, errUnsafeControl
				}
				bytesSeen += 6
				index += 6
				continue
			}
			if !bytes.ContainsRune([]byte{'"', '\\', '/', 'b', 'f', 'n', 'r', 't'}, rune(escaped)) {
				return 0, errMalformedJSON
			}
			bytesSeen += 2
			index += 2
		case b == 0x1b || b == 0x9d:
			return 0, errUnsafeControl
		case b < 0x20:
			return 0, errMalformedJSON
		default:
			bytesSeen++
			index++
		}
		if bytesSeen > v0StringBytes {
			return 0, errStringTooLarge
		}
	}
	return 0, errMalformedJSON
}

func isHex(value []byte) bool {
	if len(value) != 4 {
		return false
	}
	_, err := hex.DecodeString(string(value))
	return err == nil
}

func matchingContainer(open, close byte) bool {
	return (open == '{' && close == '}') || (open == '[' && close == ']')
}

func validateV0MessageValue(value any, depth int) error {
	if depth > v0JSONDepth {
		return errJSONDepth
	}
	switch typed := value.(type) {
	case map[string]any:
		if len(typed) > v0CollectionItems {
			return errCollectionTooLarge
		}
		for key, nested := range typed {
			if len(key) > v0StringBytes || !utf8.ValidString(key) {
				return errStringTooLarge
			}
			if hasUnsafeControl(key) {
				return errUnsafeControl
			}
			if err := validateV0MessageValue(nested, depth+1); err != nil {
				return err
			}
		}
	case []any:
		if len(typed) > v0CollectionItems {
			return errCollectionTooLarge
		}
		for _, nested := range typed {
			if err := validateV0MessageValue(nested, depth+1); err != nil {
				return err
			}
		}
	case string:
		if len(typed) > v0StringBytes {
			return errStringTooLarge
		}
		if !utf8.ValidString(typed) {
			return errInvalidUTF8
		}
		if hasUnsafeControl(typed) {
			return errUnsafeControl
		}
	case nil, bool, float64, float32,
		int, int8, int16, int32, int64,
		uint, uint8, uint16, uint32, uint64:
		return nil
	default:
		return fmt.Errorf("unsupported JSON value %T", value)
	}
	return nil
}

func hasUnsafeControl(value string) bool {
	return bytes.ContainsRune([]byte(value), rune(0x1b)) || bytes.ContainsRune([]byte(value), rune(0x9d))
}

func validateDaemonFrameSchema(message map[string]any) error {
	allowed := map[string]struct{}{
		"type": {}, "protocol_version": {}, "invocation_id": {}, "attempt_id": {},
		"mission_id": {}, "workspace_path": {}, "workspace_generation": {},
		"fencing_generation": {}, "fencing_token": {}, "seq": {}, "mac": {},
	}
	switch message["type"] {
	case "cancel":
		allowed["reason"] = struct{}{}
	case "ping", "checkpoint_request":
	default:
		return errors.New("unsupported daemon frame type")
	}
	return validateAllowedFields(message, allowed)
}

func validateRunnerFrameSchema(message map[string]any) error {
	allowed := map[string]struct{}{
		"type": {}, "protocol_version": {}, "invocation_id": {}, "attempt_id": {},
		"mission_id": {}, "workspace_path": {}, "workspace_generation": {},
		"fencing_generation": {}, "fencing_token": {}, "seq": {}, "mac": {},
	}
	switch message["type"] {
	case "runner_started":
		for _, key := range []string{"runner_pid", "harness_pid", "pgid", "harness_executable_path", "harness_executable_sha256", "started_at", "manifest_digest", "runner_executable_sha256"} {
			allowed[key] = struct{}{}
		}
	case "stdout_chunk", "stderr_chunk":
		allowed["native_sequence"] = struct{}{}
		allowed["data"] = struct{}{}
	case "harness_exited":
		allowed["exit_code"] = struct{}{}
		allowed["signaled"] = struct{}{}
	case "termination_complete":
		allowed["verified_dead"] = struct{}{}
		allowed["termination_reason"] = struct{}{}
	case "pong":
	default:
		return errors.New("unsupported runner frame type")
	}
	return validateAllowedFields(message, allowed)
}

func validateAllowedFields(message map[string]any, allowed map[string]struct{}) error {
	for key := range message {
		if _, ok := allowed[key]; !ok {
			return fmt.Errorf("unknown frame field %q", key)
		}
	}
	return nil
}
