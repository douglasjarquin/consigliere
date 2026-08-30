package client

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

var errConfirmationRequired = fmt.Errorf("explicit confirmation required")

func Run(args []string, stdout, stderr io.Writer) int {
	return runWithInput(args, stdout, stderr, os.Stdin)
}

func runWithInput(args []string, stdout, stderr io.Writer, input io.Reader) int {
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

	op, payload, err := mapCommand(cmd, pos, opts)
	if err != nil {
		fmt.Fprintln(stderr, err.Error())
		if strings.Contains(err.Error(), "usage") || strings.Contains(err.Error(), "unknown") {
			fmt.Fprint(stderr, usage())
			return ExitUsage
		}
		return ExitUsage
	}
	if task5BossOperation(op) {
		boss = true
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

	if workflowMutation(op) {
		confirmed, preview, previewErr := confirmWorkflow(cmd, op, payload, opts, d, stdout, input)
		if previewErr != nil {
			if jsonOut {
				return printJSON(stdout, stderr, preview, previewErr)
			}
			PrintError(stderr, previewErr, preview)
			return ExitFor(previewErr, preview)
		}
		if !confirmed {
			confirmation := localResponse("confirmation_required", "explicit confirmation is required")
			if jsonOut {
				return printJSON(stdout, stderr, confirmation, nil)
			}
			PrintError(stderr, nil, confirmation)
			return ExitUsage
		}
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
cs project add --name NAME --path PATH [--url URL] [--default-branch BRANCH]
cs project <id>
cs missions
cs mission <id>
cs mission create --project PROJECT --objective TEXT --scope TEXT --acceptance TEXT
cs mission submit MISSION
cs mission continue MISSION --sha CHECKPOINT_SHA
cs mission request-changes MISSION --reason TEXT
cs mission authorize MISSION
cs orient --json [--project PROJECT] [--mission MISSION]
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

func advisoryIntOption(opts map[string]string, key string) (int, bool, error) {
	raw, present := opts[key]
	if !present || raw == "" {
		return 0, false, nil
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value < 0 {
		return 0, false, fmt.Errorf("invalid --%s: expected a non-negative integer", strings.ReplaceAll(key, "_", "-"))
	}
	return value, true, nil
}

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
		if pos[0] == "add" {
			if opts["name"] == "" || opts["path"] == "" {
				return "", nil, fmt.Errorf("usage: cs project add --name NAME --path PATH")
			}
			branch := opts["default_branch"]
			if branch == "" {
				branch = opts["branch"]
			}
			if branch == "" {
				branch = "main"
			}
			payload := map[string]any{
				"name":            opts["name"],
				"repository_path": opts["path"],
				"default_branch":  branch,
			}
			if opts["url"] != "" {
				payload["repository_url"] = opts["url"]
			}
			return "project.add", payload, nil
		}
		return "project.get", map[string]any{"project_id": pos[0]}, nil
	case "missions":
		return "mission.list", map[string]any{}, nil
	case "mission":
		if len(pos) == 0 {
			return "", nil, fmt.Errorf("usage: cs mission <id>")
		}
		switch pos[0] {
		case "create":
			projectID := opts["project"]
			if projectID == "" {
				projectID = opts["project_id"]
			}
			if projectID == "" || opts["objective"] == "" || opts["scope"] == "" || opts["acceptance"] == "" {
				return "", nil, fmt.Errorf("usage: cs mission create --project PROJECT --objective TEXT --scope TEXT --acceptance TEXT")
			}
			return "mission.create", map[string]any{
				"project_id":          projectID,
				"objective":           opts["objective"],
				"scope":               opts["scope"],
				"acceptance_criteria": opts["acceptance"],
			}, nil
		case "submit":
			if len(pos) < 2 || pos[1] == "" {
				return "", nil, fmt.Errorf("usage: cs mission submit MISSION")
			}
			return "mission.submit", map[string]any{"mission_id": pos[1]}, nil
		case "request-changes", "request_changes":
			if len(pos) < 2 || pos[1] == "" || opts["reason"] == "" {
				return "", nil, fmt.Errorf("usage: cs mission request-changes MISSION --reason TEXT")
			}
			return "mission.request_changes", map[string]any{
				"mission_id": pos[1],
				"reason":     opts["reason"],
			}, nil
		case "authorize":
			if len(pos) < 2 || pos[1] == "" {
				return "", nil, fmt.Errorf("usage: cs mission authorize MISSION")
			}
			return "mission.grant_work", map[string]any{"mission_id": pos[1]}, nil
		case "continue":
			if len(pos) < 2 || pos[1] == "" || opts["sha"] == "" {
				return "", nil, fmt.Errorf("usage: cs mission continue MISSION --sha CHECKPOINT_SHA")
			}
			return "mission.continue", map[string]any{
				"mission_id":     pos[1],
				"checkpoint_sha": opts["sha"],
			}, nil
		default:
			return "mission.get", map[string]any{"mission_id": pos[0]}, nil
		}
	case "orient":
		if len(pos) != 0 {
			return "", nil, fmt.Errorf("usage: cs orient --json [--project PROJECT] [--mission MISSION]")
		}

		payload := map[string]any{}
		for _, key := range []string{
			"project", "mission", "session_id", "model", "effort", "cli_version", "context_hash",
		} {
			if value := opts[key]; value != "" {
				switch key {
				case "project":
					payload["project_id"] = value
				case "mission":
					payload["mission_id"] = value
				default:
					payload[key] = value
				}
			}
		}

		for _, key := range []string{
			"turn", "compactions", "resets", "human_interventions",
			"input_tokens", "output_tokens", "cached_input_tokens", "total_tokens",
		} {
			if value, present, err := advisoryIntOption(opts, key); err != nil {
				return "", nil, err
			} else if present {
				payload[key] = value
			}
		}

		return "advisory.orient", payload, nil
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
	case "project":
		if id := firstString(payload, "id"); id != "" {
			fmt.Fprintf(w, "project %s name=%s default_branch=%s base_sha=%s base_ref=%s\n",
				id,
				firstString(payload, "name"),
				firstString(payload, "default_branch"),
				firstString(payload, "base_sha"),
				firstString(payload, "base_ref"),
			)
			return
		}
		printRows(w, payload)
	case "mission":
		if id := firstString(payload, "id"); id != "" {
			printMissionSummary(w, payload)
			if auth := firstString(payload, "authorization_id"); auth != "" {
				fmt.Fprintf(w, "authorization: %s\n", auth)
			}
			printMissionEvidence(w, payload, "")
			return
		}
		printRows(w, payload)
	case "review":
		if rows, ok := payload["missions"].([]any); ok {
			for _, raw := range rows {
				if row, ok := raw.(map[string]any); ok {
					printMissionSummary(w, row)
					printMissionEvidence(w, row, "")
				}
			}
			return
		}
		printRows(w, payload)
	case "orient":
		projects, _ := payload["projects"].([]any)
		missions, _ := payload["missions"].([]any)
		fmt.Fprintf(w, "orientation version=%v snapshot_bytes=%v ledger=%v projects=%d missions=%d\n",
			payload["snapshot_version"],
			payload["snapshot_bytes"],
			payload["ledger_status"],
			len(projects),
			len(missions),
		)
	case "health":
		fmt.Fprintf(w, "status=%v protocol=%v release=%v schema=%v harness=%v\n",
			payload["status"], payload["protocol"], payload["release"], payload["schema"], payload["harness"])
	case "why":
		fmt.Fprintf(w, "mission %v phase=%v runnable=%v reason=%v\n",
			payload["id"], payload["phase"], payload["runnable"], payload["reason"])
		fmt.Fprintf(w, "  project=%s base_sha=%s checkpoint_sha=%s\n",
			firstString(payload, "project_id"),
			firstString(payload, "base_sha"),
			firstString(payload, "current_checkpoint_sha"),
		)
		printMissionEvidence(w, payload, "  ")
		if pr, ok := payload["phase_reason"].(string); ok && pr != "" {
			fmt.Fprintf(w, "  %s\n", pr)
		}
		if dispatch, ok := payload["dispatch"].(map[string]any); ok && dispatch != nil {
			fmt.Fprintf(w, "  dispatch id=%v status=%v slot=%v child=%v attempt=%v workspace=%v runner=%v\n",
				dispatch["id"],
				dispatch["status"],
				dispatch["slot_state"],
				dispatch["child_start_state"],
				dispatch["attempt_id"],
				dispatch["workspace_path"],
				dispatch["runner_pid"],
			)
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

func printMissionSummary(w io.Writer, payload map[string]any) {
	fmt.Fprintf(w, "mission %s phase=%s project=%s base_sha=%s checkpoint_sha=%s\n",
		firstString(payload, "id"),
		firstString(payload, "phase"),
		firstString(payload, "project_id"),
		firstString(payload, "base_sha"),
		firstString(payload, "current_checkpoint_sha"),
	)
}

func printMissionEvidence(w io.Writer, payload map[string]any, prefix string) {
	fmt.Fprintf(w, "%sresult: sha=%s status=%s kind=%s ref=%s\n",
		prefix,
		firstString(payload, "result_sha"),
		firstString(payload, "result_status"),
		firstString(payload, "result_kind"),
		firstString(payload, "result_ref"),
	)

	if workspace, ok := payload["workspace"].(map[string]any); ok {
		fmt.Fprintf(w, "%sworkspace: id=%s attempt=%s generation=%s status=%s path=%s\n",
			prefix,
			firstString(workspace, "id"),
			firstString(workspace, "attempt_id"),
			firstString(workspace, "generation"),
			firstString(workspace, "status"),
			firstString(workspace, "path"),
		)
	}

	if verification, ok := payload["verification"].([]any); ok {
		for _, raw := range verification {
			if run, ok := raw.(map[string]any); ok {
				fmt.Fprintf(w, "%sverification: gate=%s ordinal=%s outcome=%s input_sha=%s output_digest=%s\n",
					prefix,
					firstString(run, "gate_type"),
					firstString(run, "ordinal"),
					firstString(run, "outcome"),
					firstString(run, "input_sha"),
					firstString(run, "output_digest"),
				)
			}
		}
	}
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

func task5BossOperation(op string) bool {
	switch op {
	case "project.add", "mission.create", "mission.submit", "mission.request_changes", "mission.grant_work", "mission.continue":
		return true
	default:
		return false
	}
}

func workflowMutation(op string) bool {
	return task5BossOperation(op)
}

func localResponse(code, reason string) *Response {
	return &Response{
		V:     ProtocolVersion,
		OK:    false,
		Error: &ErrorBody{Code: code, Reason: reason},
	}
}

func confirmWorkflow(cmd, op string, payload map[string]any, opts map[string]string, d Dialer, stdout io.Writer, input io.Reader) (bool, *Response, error) {
	preview, response, err := workflowPreview(op, payload, d)
	if err != nil {
		if response == nil {
			response = localResponse("daemon", err.Error())
		}
		return false, response, err
	}

	yes := opts["yes"] == "true"
	if yes {
		if opts["idempotency_key"] == "" && !terminalInput(input) {
			return false, localResponse("confirmation_required", "--yes automation requires --idempotency-key"), errConfirmationRequired
		}
		return true, nil, nil
	}

	if !terminalInput(input) && input == os.Stdin {
		return false, localResponse("confirmation_required", "run in a foreground terminal or pass --yes with --idempotency-key"), errConfirmationRequired
	}

	fmt.Fprintln(stdout, confirmationText(cmd, op, payload, preview))
	fmt.Fprint(stdout, "Confirm [y/N]: ")
	line, readErr := bufio.NewReader(input).ReadString('\n')
	if readErr != nil && len(line) == 0 {
		return false, localResponse("confirmation_declined", "confirmation was not provided"), errConfirmationRequired
	}
	if strings.EqualFold(strings.TrimSpace(line), "y") || strings.EqualFold(strings.TrimSpace(line), "yes") {
		return true, nil, nil
	}
	return false, localResponse("confirmation_declined", "operation was not confirmed"), errConfirmationRequired
}

func workflowPreview(op string, payload map[string]any, d Dialer) (map[string]any, *Response, error) {
	var previewOp string
	var previewPayload map[string]any
	switch op {
	case "mission.create":
		previewOp = "project.get"
		previewPayload = map[string]any{"project_id": payload["project_id"]}
	case "mission.submit", "mission.request_changes", "mission.grant_work", "mission.continue":
		previewOp = "mission.get"
		previewPayload = map[string]any{"mission_id": payload["mission_id"]}
	default:
		return payload, nil, nil
	}

	response, err := d.Call(previewOp, previewPayload, "preview", "")
	if err != nil {
		return nil, response, err
	}
	if response == nil || !response.OK {
		return nil, response, fmt.Errorf("preview request failed")
	}
	var preview map[string]any
	if err := json.Unmarshal(response.Payload, &preview); err != nil {
		return nil, response, fmt.Errorf("preview response malformed")
	}
	return preview, response, nil
}

func confirmationText(cmd, op string, payload, preview map[string]any) string {
	projectID := firstString(preview, "project_id")
	projectName := firstString(preview, "name")
	if projectID == "" {
		projectID = firstString(payload, "project_id")
	}
	if projectName == "" {
		projectName = firstString(payload, "name")
	}
	missionID := firstString(preview, "id")
	if missionID == "" {
		missionID = "<new>"
	}
	baseSHA := firstString(preview, "base_sha")
	if baseSHA == "" {
		baseSHA = "<daemon-assigned>"
	}

	objective := firstString(preview, "objective")
	if objective == "" {
		objective = firstString(payload, "objective")
	}
	scope := firstString(preview, "scope")
	if scope == "" {
		scope = firstString(payload, "scope")
	}
	acceptance := firstString(preview, "acceptance_criteria")
	if acceptance == "" {
		acceptance = firstString(payload, "acceptance_criteria")
	}

	return fmt.Sprintf(
		"Confirm %s (%s)\nProject: %s %s\nMission ID: %s\nObjective: %s\nScope: %s\nAcceptance criteria: %s\nImmutable base SHA: %s",
		cmd,
		op,
		projectID,
		projectName,
		missionID,
		objective,
		scope,
		acceptance,
		baseSHA,
	)
}

func terminalInput(input io.Reader) bool {
	file, ok := input.(*os.File)
	if !ok {
		return false
	}
	info, err := file.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
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
