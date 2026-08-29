package client

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

func Run(args []string, stdout, stderr io.Writer) int {
	jsonOut := false
	filtered := make([]string, 0, len(args))
	for _, a := range args {
		if a == "--json" {
			jsonOut = true
			continue
		}
		if a == "--help" || a == "-h" {
			fmt.Fprint(stdout, usage())
			return ExitOK
		}
		filtered = append(filtered, a)
	}
	if len(filtered) == 0 {
		fmt.Fprint(stdout, usage())
		return ExitUsage
	}

	home := ResolveHome()
	cmd, rest := filtered[0], filtered[1:]
	opts, pos := parseFlags(rest)

	if cmd == "cutover" {
		return printCutover(stdout, stderr)
	}

	switch cmd {
	case "doctor":
		return runDoctor(home, jsonOut, stdout, stderr)
	case "version":
		return runVersion(home, jsonOut, stdout, stderr)
	}

	boss := false
	if cmd == "boss" {
		if len(rest) == 0 {
			fmt.Fprintln(stderr, "usage: cs boss <command>")
			return ExitUsage
		}
		boss = true
		cmd, rest = rest[0], rest[1:]
		opts, pos = parseFlags(rest)
	}

	d := NewDialer(home)
	if boss {
		d = NewBossDialer(home)
	}
	if v := os.Getenv("CS_PROTOCOL_VERSION"); v != "" {
		fmt.Sscanf(v, "%d", &d.Version)
	}
	if p := os.Getenv("CS_SOCKET"); p != "" {
		d.Socket = p
	}

	op, payload, err := mapCommand(cmd, pos, opts)
	if err != nil {
		fmt.Fprintln(stderr, err.Error())
		if strings.Contains(err.Error(), "usage") || strings.Contains(err.Error(), "unknown") {
			fmt.Fprint(stderr, usage())
			return ExitUsage
		}
		return ExitUsage
	}

	idem := opts["idempotency_key"]
	resp, callErr := d.Call(op, payload, opts["id"], idem)
	if jsonOut {
		return printJSON(stdout, stderr, resp, callErr)
	}
	if callErr != nil {
		PrintError(stderr, callErr, resp)
		return ExitFor(callErr, resp)
	}
	if resp != nil && !resp.OK {
		PrintError(stderr, nil, resp)
		return ExitError
	}
	printHuman(stdout, cmd, pos, resp)
	return ExitOK
}

func usage() string {
	return `cs - consigliere client

cs health
cs version
cs doctor
cs ping
cs projects
cs project <id>
cs missions
cs mission <id>
cs mission create --project-id ID --objective TEXT --scope TEXT --acceptance TEXT
cs why <mission-id>
cs inbox
cs review
cs attempts
cs attempt logs <attempt-id>
cs incidents
cs events
cs cutover

cs boss away
cs boss return
cs boss answer <question-id> --text TEXT
cs boss authorize-merge <mission-id> --pr N --sha SHA
cs boss pause <mission-id>
cs boss resume <mission-id>
cs boss cancel <mission-id>
cs boss reconcile

Use --json for machine output. Default cs is advisory (api.sock).
cs boss talks to CS_HOME/priv.sock with the human credential.
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
		key := strings.TrimPrefix(a, "--")
		if strings.Contains(key, "=") {
			parts := strings.SplitN(key, "=", 2)
			opts[canon(parts[0])] = parts[1]
			continue
		}
		if i+1 < len(args) && !strings.HasPrefix(args[i+1], "-") {
			i++
			opts[canon(key)] = args[i]
			continue
		}
		opts[canon(key)] = "true"
	}
	return opts, pos
}

func canon(s string) string { return strings.ReplaceAll(s, "-", "_") }

func mapCommand(cmd string, pos []string, opts map[string]string) (string, map[string]any, error) {
	switch cmd {
	case "health":
		return "health", map[string]any{}, nil
	case "ping":
		return "ping", map[string]any{}, nil
	case "projects":
		return "project.list", map[string]any{}, nil
	case "project":
		if len(pos) == 0 {
			return "", nil, fmt.Errorf("usage: cs project <id>")
		}
		return "project.get", map[string]any{"project_id": pos[0]}, nil
	case "missions":
		return "mission.list", map[string]any{}, nil
	case "mission":
		if len(pos) == 0 {
			return "", nil, fmt.Errorf("usage: cs mission <id>")
		}
		if pos[0] == "create" {
			return "mission.create", map[string]any{
				"project_id":          opts["project_id"],
				"objective":           opts["objective"],
				"scope":               opts["scope"],
				"acceptance_criteria": opts["acceptance"],
			}, nil
		}
		return "mission.get", map[string]any{"mission_id": pos[0]}, nil
	case "why":
		if len(pos) == 0 {
			return "", nil, fmt.Errorf("usage: cs why <mission-id>")
		}
		return "mission.why", map[string]any{"mission_id": pos[0]}, nil
	case "inbox":
		return "questions.inbox", map[string]any{}, nil
	case "away":
		return "away.mark", map[string]any{}, nil
	case "return":
		return "away.return", map[string]any{}, nil
	case "answer":
		if len(pos) == 0 || opts["text"] == "" {
			return "", nil, fmt.Errorf("usage: cs answer <question-id> --text TEXT")
		}
		return "question.answer", map[string]any{"question_id": pos[0], "answer": opts["text"]}, nil
	case "review":
		return "mission.review", map[string]any{}, nil
	case "authorize-merge":
		if len(pos) == 0 || opts["pr"] == "" || opts["sha"] == "" {
			return "", nil, fmt.Errorf("usage: cs authorize-merge <mission-id> --pr N --sha SHA")
		}
		return "mission.grant_integration", map[string]any{
			"mission_id":          pos[0],
			"target_pull_request": opts["pr"],
			"target_sha":          opts["sha"],
		}, nil
	case "pause":
		if len(pos) == 0 {
			return "", nil, fmt.Errorf("usage: cs pause <mission-id>")
		}
		return "mission.pause", map[string]any{"mission_id": pos[0]}, nil
	case "resume":
		if len(pos) == 0 {
			return "", nil, fmt.Errorf("usage: cs resume <mission-id>")
		}
		return "mission.resume", map[string]any{"mission_id": pos[0]}, nil
	case "cancel":
		if len(pos) == 0 {
			return "", nil, fmt.Errorf("usage: cs cancel <mission-id>")
		}
		return "mission.cancel", map[string]any{"mission_id": pos[0], "reason": opts["reason"]}, nil
	case "attempts":
		return "attempt.list", map[string]any{}, nil
	case "attempt":
		if len(pos) >= 2 && pos[0] == "logs" {
			return "attempt.logs", map[string]any{"attempt_id": pos[1]}, nil
		}
		return "", nil, fmt.Errorf("usage: cs attempt logs <attempt-id>")
	case "incidents":
		return "incident.list", map[string]any{}, nil
	case "events":
		return "event.list", map[string]any{}, nil
	case "reconcile":
		return "reconcile", map[string]any{}, nil
	default:
		return "", nil, fmt.Errorf("unknown command: %s", cmd)
	}
}

func printJSON(stdout, stderr io.Writer, resp *Response, err error) int {
	if resp == nil {
		PrintError(stderr, err, nil)
		return ExitFor(err, nil)
	}
	enc := json.NewEncoder(stdout)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(resp); err != nil {
		fmt.Fprintln(stderr, err)
		return ExitError
	}
	if err != nil {
		return ExitFor(err, resp)
	}
	if !resp.OK {
		return ExitError
	}
	return ExitOK
}

func printHuman(w io.Writer, cmd string, pos []string, resp *Response) {
	if resp == nil {
		return
	}
	var payload map[string]any
	_ = json.Unmarshal(resp.Payload, &payload)
	if payload == nil {
		payload = map[string]any{}
	}
	switch cmd {
	case "ping":
		fmt.Fprintln(w, "pong")
	case "health":
		fmt.Fprintf(w, "status=%v protocol=%v release=%v schema=%v harness=%v\n",
			payload["status"], payload["protocol"], payload["release"], payload["schema"], payload["harness"])
	case "why":
		fmt.Fprintf(w, "mission %v phase=%v runnable=%v reason=%v\n",
			payload["id"], payload["phase"], payload["runnable"], payload["reason"])
		if pr, ok := payload["phase_reason"].(string); ok && pr != "" {
			fmt.Fprintf(w, "  %s\n", pr)
		}
		if blockers, ok := payload["blockers"].([]any); ok {
			for _, raw := range blockers {
				b, _ := raw.(map[string]any)
				fmt.Fprintf(w, "  blocker kind=%v reason=%v\n", b["kind"], b["reason"])
			}
		}
	case "attempt":
		if lines, ok := payload["lines"].([]any); ok {
			for _, line := range lines {
				fmt.Fprintln(w, line)
			}
		}
		if path, ok := payload["path"].(string); ok && path != "" {
			fmt.Fprintf(w, "path: %s\n", path)
		}
	default:
		printRows(w, payload)
	}
	_ = pos
}

func printRows(w io.Writer, payload map[string]any) {
	for _, key := range []string{"missions", "projects", "questions", "attempts", "incidents", "events"} {
		rows, ok := payload[key].([]any)
		if !ok {
			continue
		}
		if len(rows) == 0 {
			fmt.Fprintf(w, "(no %s)\n", key)
			return
		}
		for _, raw := range rows {
			row, _ := raw.(map[string]any)
			id := firstString(row, "id")
			extra := firstString(row, "phase", "status", "name", "type", "severity")
			tail := firstString(row, "objective", "prompt", "reason", "repository_url")
			fmt.Fprintf(w, "%s %s %s\n", id, extra, tail)
		}
		return
	}
	if id, ok := payload["id"]; ok {
		fmt.Fprintf(w, "%v %v\n", id, firstString(payload, "phase", "status"))
		return
	}
	b, _ := json.Marshal(payload)
	fmt.Fprintln(w, string(b))
}

func firstString(m map[string]any, keys ...string) string {
	for _, k := range keys {
		if v, ok := m[k]; ok && v != nil {
			return fmt.Sprint(v)
		}
	}
	return ""
}

func runDoctor(home Home, jsonOut bool, stdout, stderr io.Writer) int {
	boss := Probe(home.BossSocket())
	priv := Probe(home.PrivilegedSocket())
	api := Probe(home.APISocket())
	lockState, lockPid := ProbeLock(home.LockPath())
	lock := string(lockState)
	if lockState == LockHeld && lockPid > 0 {
		lock = "held"
	}
	cred := "absent"
	if _, err := os.Stat(home.CredentialPath()); err == nil {
		cred = "present"
	}
	doc := map[string]any{
		"home":        home.Dir,
		"database":    home.DatabasePath(),
		"lock":        lock,
		"lock_pid":    lockPid,
		"credential":  cred,
		"boss_socket": string(boss),
		"priv_socket": string(priv),
		"api_socket":  string(api),
	}
	ownerState, ownerReason := ProbeOwner(home.OwnerPath())
	doc["owner"] = string(ownerState)
	if ownerReason != "" {
		doc["owner_error"] = ownerReason
	}
	if err := home.LastError(); err != "" {
		doc["last_error"] = err
	}
	codexAuth := filepath.Join(home.Dir, "runtime", "codex", "auth.json")
	codexStatus := "absent"
	if _, err := os.Stat(codexAuth); err == nil {
		codexStatus = "ready"
	} else if _, err := os.Stat(filepath.Join(home.Dir, "runtime", "codex")); err == nil {
		codexStatus = "missing"
	}
	doc["codex_auth"] = codexStatus

	exit := ExitOK
	switch priv {
	case SocketAbsent:
		exit = ExitAbsent
	case SocketStale:
		exit = ExitStale
	default:
		d := NewDialer(home)
		if resp, err := d.Call("health", map[string]any{}, "doctor", ""); err == nil && resp.OK {
			var payload map[string]any
			_ = json.Unmarshal(resp.Payload, &payload)
			doc["health"] = payload
		} else if err != nil {
			doc["health_error"] = err.Error()
		}
	}

	if jsonOut {
		enc := json.NewEncoder(stdout)
		enc.SetEscapeHTML(false)
		_ = enc.Encode(doc)
		return exit
	}
	fmt.Fprintf(stdout, "home: %s\n", home.Dir)
	fmt.Fprintf(stdout, "database: %s\n", home.DatabasePath())
	if lockState == LockHeld && lockPid > 0 {
		fmt.Fprintf(stdout, "lock: %s held pid=%d\n", home.LockPath(), lockPid)
	} else {
		fmt.Fprintf(stdout, "lock: %s %s\n", home.LockPath(), lock)
	}
	fmt.Fprintf(stdout, "credential: %s\n", cred)
	fmt.Fprintf(stdout, "probe socket: %s (%s)\n", boss, home.BossSocket())
	fmt.Fprintf(stdout, "priv socket: %s\n", priv)
	fmt.Fprintf(stdout, "api socket: %s\n", api)
	if err := home.LastError(); err != "" {
		fmt.Fprintf(stdout, "last startup failure: %s\n", strings.TrimSpace(err))
	}
	fmt.Fprintf(stdout, "codex auth: %s\n", codexStatus)
	if health, ok := doc["health"].(map[string]any); ok {
		fmt.Fprintf(stdout, "release: %v schema: %v harness: %v runner: %v\n",
			health["release"], health["schema"], health["harness"], health["runner"])
	}
	_ = stderr
	return exit
}

func runVersion(home Home, jsonOut bool, stdout, stderr io.Writer) int {
	out := map[string]any{"cs": ClientVersion, "protocol": ProtocolVersion}
	d := NewDialer(home)
	if Probe(d.Socket) == SocketLive {
		if resp, err := d.Call("version", map[string]any{}, "version", ""); err == nil && resp.OK {
			var payload map[string]any
			_ = json.Unmarshal(resp.Payload, &payload)
			out["daemon"] = payload
		}
	}
	if jsonOut {
		enc := json.NewEncoder(stdout)
		enc.SetEscapeHTML(false)
		_ = enc.Encode(out)
		return ExitOK
	}
	fmt.Fprintf(stdout, "cs %s protocol=%d\n", ClientVersion, ProtocolVersion)
	if daemon, ok := out["daemon"].(map[string]any); ok {
		fmt.Fprintf(stdout, "daemon %v protocol=%v\n", daemon["release"], daemon["protocol"])
	}
	_ = stderr
	return ExitOK
}

func printCutover(stdout, stderr io.Writer) int {
	candidates := []string{}
	if rel := os.Getenv("CS_RELEASE"); rel != "" {
		candidates = append(candidates, filepath.Join(rel, "lib", "consigliere_daemon-0.1.0", "priv", "cutover.md"))
		candidates = append(candidates, filepath.Join(rel, "priv", "cutover.md"))
	}
	if exe, err := os.Executable(); err == nil {
		candidates = append(candidates, filepath.Join(filepath.Dir(exe), "..", "share", "consigliere", "cutover.md"))
	}
	for _, p := range candidates {
		b, err := os.ReadFile(p)
		if err == nil {
			fmt.Fprint(stdout, string(b))
			return ExitOK
		}
	}
	fmt.Fprintln(stderr, "cutover runbook is not packaged next to this binary; see docs/cutover.md")
	return ExitError
}
