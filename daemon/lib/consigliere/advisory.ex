defmodule Consigliere.Advisory do
  @moduledoc """
  Bounded, read-only state projection for the model-advisory principal.

  The projection deliberately omits filesystem paths, credentials, process
  controls, command argv, raw logs, and repository URLs. Advisory output is
  data for a model session, never an authority transition.
  """

  import Ecto.Query

  alias Consigliere.AdvisoryLedger
  alias Consigliere.AttemptResults.AttemptResult
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Harness.Redaction
  alias Consigliere.Incidents.Incident
  alias Consigliere.MissionBlockers.MissionBlocker
  alias Consigliere.Missions.Mission
  alias Consigliere.ProjectVerifications
  alias Consigliere.Projects.Project
  alias Consigliere.Questions.Question
  alias Consigliere.Repo
  alias Consigliere.V0.Limits
  alias Consigliere.Workspaces.Workspace

  @snapshot_version 1
  @max_projects 16
  @max_missions 64
  @max_attempts 64
  @max_questions 64
  @max_incidents 64
  @max_blockers 64
  @max_verifications 8
  @max_text_bytes 512
  @max_id_bytes Limits.string_bytes()
  @hidden_keys ~w(api_socket argv boss_socket capability credential database database_path
                   home lines lock path password priv_socket raw_output repository_path
                   repository_url secret sqlite_path transcript trusted_mirror_path
                   workspace_path)

  def orient(filters \\ %{}, metadata \\ %{})

  def orient(filters, metadata) when is_map(filters) and is_map(metadata) do
    with {:ok, filters} <- normalize_filters(filters),
         {:ok, mission_filter} <- fetch_mission(filters.mission_id),
         :ok <- match_project_filter(filters.project_id, mission_filter),
         {:ok, snapshot} <- build_snapshot(filters, mission_filter),
         {:ok, snapshot} <- bound_snapshot(snapshot) do
      ledger_status =
        case AdvisoryLedger.record(
               Map.merge(%{"system" => "advisory", "outcome" => "accepted"}, metadata),
               metadata,
               snapshot["snapshot_bytes"]
             ) do
          {:ok, :recorded} -> "recorded"
          {:error, _reason} -> "unavailable"
        end

      {:ok, Map.put(snapshot, "ledger_status", ledger_status)}
    end
  end

  def orient(_filters, _metadata), do: {:error, {:invalid, :orientation_filters_invalid}}

  def sanitize_result({:ok, value}), do: {:ok, sanitize(value)}
  def sanitize_result(other), do: other

  def sanitize_logs_result({:ok, %{"attempt_id" => attempt_id, "lines" => lines}}) do
    {:ok, %{"attempt_id" => sanitize(attempt_id), "lines" => sanitize(lines)}}
  end

  def sanitize_logs_result(other), do: sanitize_result(other)

  def sanitize(value, depth \\ 0)

  def sanitize(_value, depth) when depth > 6, do: "truncated"

  def sanitize(value, _depth) when is_binary(value),
    do: value |> Redaction.text() |> String.slice(0, @max_text_bytes)

  def sanitize(value, _depth) when is_boolean(value) or is_integer(value) or is_float(value),
    do: value

  def sanitize(nil, _depth), do: nil

  def sanitize(value, depth) when is_list(value) do
    Enum.map(Enum.take(value, Limits.collection_items()), &sanitize(&1, depth + 1))
  end

  def sanitize(value, depth) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      key = to_string(key)

      if key in @hidden_keys do
        acc
      else
        Map.put(acc, key, sanitize(nested, depth + 1))
      end
    end)
  end

  def sanitize(_value, _depth), do: "redacted"

  defp normalize_filters(filters) do
    with {:ok, project_id} <-
           optional_id(Map.get(filters, "project_id") || Map.get(filters, :project_id)),
         {:ok, mission_id} <-
           optional_id(Map.get(filters, "mission_id") || Map.get(filters, :mission_id)) do
      {:ok, %{project_id: project_id, mission_id: mission_id}}
    else
      {:error, _reason} -> {:error, {:invalid, :orientation_filters_invalid}}
    end
  end

  defp optional_id(nil), do: {:ok, nil}

  defp optional_id(value)
       when is_binary(value) and byte_size(value) > 0 and
              byte_size(value) <= @max_id_bytes do
    case Limits.validate_text(value) do
      :ok -> {:ok, value}
      {:error, _reason} -> {:error, :invalid_id}
    end
  end

  defp optional_id(_value), do: {:error, :invalid_id}

  defp fetch_mission(nil), do: {:ok, nil}

  defp fetch_mission(id) do
    case Repo.get(Mission, id) do
      %Mission{} = mission -> {:ok, mission}
      nil -> {:error, {:not_found, "mission"}}
    end
  end

  defp match_project_filter(nil, _mission), do: :ok

  defp match_project_filter(project_id, %Mission{project_id: project_id}), do: :ok

  defp match_project_filter(project_id, %Mission{}) when is_binary(project_id),
    do: {:error, {:invalid, :orientation_filter_mismatch}}

  defp match_project_filter(project_id, nil) do
    if Repo.exists?(from(p in Project, where: p.id == ^project_id)) do
      :ok
    else
      {:error, {:not_found, "project"}}
    end
  end

  defp build_snapshot(filters, mission_filter) do
    target_project_id = filters.project_id || (mission_filter && mission_filter.project_id)
    projects = project_rows(target_project_id)

    missions =
      mission_rows(target_project_id, filters.mission_id)

    mission_ids = Enum.map(missions, & &1.id)
    attempts = attempt_rows(mission_ids)
    questions = question_rows(mission_ids)
    incidents = incident_rows(mission_ids)
    blockers = blocker_rows(mission_ids)

    safe_actions = Enum.map(missions, &safe_action/1)

    snapshot = %{
      "snapshot_version" => @snapshot_version,
      "generated_at" =>
        DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
      "filters" =>
        filters
        |> Map.drop([:project_id, :mission_id])
        |> Map.merge(string_filter_values(filters)),
      "projects" => Enum.map(projects, &project_snapshot/1),
      "missions" => Enum.map(missions, &mission_snapshot/1),
      "attempts" => Enum.map(attempts, &attempt_snapshot/1),
      "questions" => Enum.map(questions, &question_snapshot/1),
      "incidents" => Enum.map(incidents, &incident_snapshot/1),
      "blockers" => Enum.map(blockers, &blocker_snapshot/1),
      "review_ready" =>
        missions
        |> Enum.filter(&(&1.phase == "ready_for_review"))
        |> Enum.map(fn mission ->
          %{"mission_id" => mission.id, "project_id" => mission.project_id}
        end),
      "safe_next_actions" => safe_actions,
      "attention_requests" => attention_requests(questions, missions),
      "snapshot_bytes" => 0,
      "ledger_status" => "pending"
    }

    {:ok, snapshot}
  end

  defp string_filter_values(%{project_id: project_id, mission_id: mission_id}) do
    %{}
    |> maybe_put("project_id", project_id)
    |> maybe_put("mission_id", mission_id)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp project_rows(nil) do
    Repo.all(
      from(p in Project,
        order_by: [asc: p.name, asc: p.id],
        limit: ^@max_projects
      )
    )
  end

  defp project_rows(project_id) do
    Repo.all(
      from(p in Project,
        where: p.id == ^project_id,
        limit: ^@max_projects
      )
    )
  end

  defp mission_rows(project_id, nil) do
    query =
      from(m in Mission,
        order_by: [desc: m.updated_at, desc: m.id],
        limit: ^@max_missions
      )

    if project_id,
      do: Repo.all(from(m in query, where: m.project_id == ^project_id)),
      else: Repo.all(query)
  end

  defp mission_rows(project_id, mission_id) do
    query = from(m in Mission, where: m.id == ^mission_id, limit: ^@max_missions)

    if project_id,
      do: Repo.all(from(m in query, where: m.project_id == ^project_id)),
      else: Repo.all(query)
  end

  defp attempt_rows([]), do: []

  defp attempt_rows(mission_ids) do
    Repo.all(
      from(a in Attempt,
        where: a.mission_id in ^mission_ids,
        order_by: [desc: a.updated_at, desc: a.id],
        limit: ^@max_attempts
      )
    )
  end

  defp question_rows([]), do: []

  defp question_rows(mission_ids) do
    Repo.all(
      from(q in Question,
        where: q.mission_id in ^mission_ids and q.status in ["open", "routed"],
        order_by: [asc: q.inserted_at, asc: q.id],
        limit: ^@max_questions
      )
    )
  end

  defp incident_rows([]), do: []

  defp incident_rows(mission_ids) do
    Repo.all(
      from(i in Incident,
        where: i.mission_id in ^mission_ids,
        order_by: [desc: i.inserted_at, desc: i.id],
        limit: ^@max_incidents
      )
    )
  end

  defp blocker_rows([]), do: []

  defp blocker_rows(mission_ids) do
    Repo.all(
      from(b in MissionBlocker,
        where: b.mission_id in ^mission_ids and b.status == "open",
        order_by: [asc: b.inserted_at, asc: b.id],
        limit: ^@max_blockers
      )
    )
  end

  defp project_snapshot(project) do
    %{
      "id" => project.id,
      "name" => safe_text(project.name),
      "default_branch" => safe_text(project.default_branch),
      "base_sha" => project.base_sha,
      "base_ref" => project.base_ref
    }
  end

  defp mission_snapshot(mission) do
    attempt = latest_attempt(mission.id)
    result = latest_result(mission.id)

    %{
      "id" => mission.id,
      "project_id" => mission.project_id,
      "phase" => mission.phase,
      "objective" => safe_text(mission.objective),
      "scope" => safe_text(mission.scope),
      "acceptance_criteria" => safe_text(mission.acceptance_criteria),
      "base_sha" => mission.base_sha,
      "current_checkpoint_sha" => mission.current_checkpoint_sha,
      "result_sha" => result && (result.imported_sha || result.reported_sha),
      "result_status" => result && result.status,
      "result_kind" => result && result.result_kind,
      "result_ref" => result && result.result_ref,
      "workspace" => workspace_snapshot(attempt),
      "verification" => verification_snapshot(attempt),
      "safe_next_action" => safe_action(mission)["action"]
    }
  end

  defp attempt_snapshot(attempt) do
    %{
      "id" => attempt.id,
      "mission_id" => attempt.mission_id,
      "workspace_id" => attempt.workspace_id,
      "status" => attempt.status,
      "role" => safe_text(attempt.role),
      "harness" => safe_text(attempt.harness),
      "exit_classification" => safe_text(attempt.exit_classification),
      "imported_sha" => attempt.imported_sha,
      "result_ref" => attempt.result_ref
    }
  end

  defp question_snapshot(question) do
    %{
      "id" => question.id,
      "mission_id" => question.mission_id,
      "attempt_id" => question.attempt_id,
      "status" => question.status,
      "blocking_scope" => question.blocking_scope,
      "requested_authority" => question.requested_authority,
      "prompt" => safe_text(question.prompt),
      "recommendation" => safe_text(question.recommendation),
      "route" => safe_text(question.route)
    }
  end

  defp incident_snapshot(incident) do
    %{
      "id" => incident.id,
      "mission_id" => incident.mission_id,
      "subject_type" => safe_text(incident.subject_type),
      "subject_id" => incident.subject_id,
      "severity" => incident.severity,
      "reason" => safe_text(incident.reason)
    }
  end

  defp blocker_snapshot(blocker) do
    %{
      "id" => blocker.id,
      "mission_id" => blocker.mission_id,
      "kind" => blocker.kind,
      "subject_type" => blocker.subject_type,
      "subject_id" => blocker.subject_id,
      "reason" => safe_text(blocker.reason)
    }
  end

  defp workspace_snapshot(nil), do: nil

  defp workspace_snapshot(%Attempt{workspace_id: workspace_id} = attempt)
       when is_binary(workspace_id) do
    case Repo.get(Workspace, workspace_id) do
      %Workspace{} = workspace ->
        %{
          "id" => workspace.id,
          "attempt_id" => attempt.id,
          "generation" => workspace.lease_id,
          "base_sha" => workspace.base_sha,
          "parent_checkpoint_sha" => workspace.parent_checkpoint_sha,
          "status" => workspace.status
        }

      nil ->
        nil
    end
  end

  defp workspace_snapshot(_attempt), do: nil

  defp verification_snapshot(nil), do: []

  defp verification_snapshot(%Attempt{} = attempt) do
    attempt.id
    |> ProjectVerifications.runs()
    |> Enum.take(@max_verifications)
    |> Enum.map(fn run ->
      %{
        "ordinal" => run.ordinal,
        "gate_type" => run.gate_type,
        "command_identity" => run.command_identity,
        "input_sha" => run.input_sha,
        "started_at" => datetime_to_iso(run.started_at),
        "finished_at" => run.finished_at && datetime_to_iso(run.finished_at),
        "exit_status" => run.exit_status,
        "timed_out" => run.timed_out,
        "output_bytes" => run.output_bytes,
        "output_digest" => run.output_digest,
        "outcome" => run.outcome,
        "error_code" => run.error_code
      }
    end)
  end

  defp latest_attempt(mission_id) do
    Repo.one(
      from(a in Attempt,
        where: a.mission_id == ^mission_id,
        order_by: [desc: a.updated_at, desc: a.id],
        limit: 1
      )
    )
  end

  defp latest_result(mission_id) do
    Repo.one(
      from(r in AttemptResult,
        where: r.mission_id == ^mission_id,
        order_by: [desc: r.updated_at, desc: r.id],
        limit: 1
      )
    )
  end

  defp safe_action(mission) do
    action = Consigliere.Progression.next_action(mission)

    %{
      "mission_id" => mission.id,
      "project_id" => mission.project_id,
      "action" => action_name(action, mission.phase),
      "reason" => safe_text(action_reason(action, mission.phase))
    }
  end

  defp action_name(:none, "draft"), do: "draft"
  defp action_name(:none, "awaiting_authorization"), do: "awaiting_authorization"
  defp action_name(:none, "authorized"), do: "start"
  defp action_name(:none, "failed"), do: "boss_decision"
  defp action_name(:none, phase), do: to_string(phase)
  defp action_name(action, _phase), do: to_string(action)

  defp action_reason(action, phase) do
    case action do
      :review -> "ready for boss review"
      :import -> "verify and import the Attempt result"
      :validate -> "run the bounded Project verification"
      :protocol_failure -> "inspect the protocol failure"
      :none -> "Mission phase is #{phase}"
      other -> to_string(other)
    end
  end

  defp attention_requests(questions, missions) do
    boss_questions =
      questions
      |> Enum.filter(&(&1.requested_authority == "boss"))
      |> Enum.map(fn question ->
        %{
          "kind" => "boss_question",
          "question_id" => question.id,
          "mission_id" => question.mission_id
        }
      end)

    reviews =
      missions
      |> Enum.filter(&(&1.phase == "ready_for_review"))
      |> Enum.map(fn mission -> %{"kind" => "review", "mission_id" => mission.id} end)

    boss_questions ++ reviews
  end

  defp bound_snapshot(snapshot) do
    snapshot =
      Enum.reduce(1..3, snapshot, fn _iteration, current ->
        Map.put(current, "snapshot_bytes", byte_size(JSON.encode!(current)))
      end)

    if byte_size(JSON.encode!(snapshot)) <= Limits.semantic_payload_bytes(),
      do: {:ok, snapshot},
      else: {:error, {:invalid, :orientation_too_large}}
  rescue
    _ -> {:error, {:invalid, :orientation_too_large}}
  end

  defp safe_text(nil), do: nil

  defp safe_text(value) do
    value
    |> Redaction.text()
    |> String.slice(0, @max_text_bytes)
  end

  defp datetime_to_iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp datetime_to_iso(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
  defp datetime_to_iso(other), do: to_string(other)
end
