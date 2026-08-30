defmodule Consigliere.Attempts.Transitions do
  @moduledoc false

  import Ecto.Query

  alias Consigliere.DatabaseWriter
  alias Consigliere.AttemptResults
  alias Consigliere.DispatchOperations
  alias Consigliere.Repo
  alias Consigliere.Txn
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Capabilities
  alias Consigliere.Missions.Mission
  alias Consigliere.Questions.Question
  alias Consigliere.MissionBlockers.MissionBlocker
  alias Consigliere.Workspaces.Workspace
  alias Consigliere.Incidents.Incident

  @terminal ~w(completed failed lost canceled superseded)
  @lost_from ~w(starting running checkpoint_requested terminating)

  def schedule(mission_id, actor, attrs) do
    DatabaseWriter.transaction(fn -> schedule_txn(mission_id, actor, attrs) end)
  end

  def schedule_txn(mission_id, actor, attrs) do
    Txn.require_principal(actor, ["boss", "daemon"])
    mission = fetch_mission!(mission_id)

    unless mission.phase == "active" do
      Txn.illegal(mission.phase, "planned", :mission_not_active)
    end

    workspace_id = Map.get(attrs, :workspace_id)

    if workspace_id do
      case Repo.get(Workspace, workspace_id) do
        nil ->
          Txn.illegal(nil, "planned", :workspace_not_found)

        workspace ->
          unless workspace.status == "released" do
            Txn.illegal(workspace.status, "planned", :workspace_not_released)
          end
      end
    end

    Txn.insert!(
      Attempt.changeset(%Attempt{}, %{
        mission_id: mission.id,
        workspace_id: workspace_id,
        retry_of_attempt_id: Map.get(attrs, :retry_of_attempt_id),
        role: Map.get(attrs, :role, "soldier"),
        harness: Map.get(attrs, :harness, "claude"),
        status: "planned",
        fencing_token: Txn.mint_fencing_token()
      })
    )
  end

  def request_spawn(attempt_id, actor) do
    DatabaseWriter.transaction(fn -> request_spawn_txn(attempt_id, actor) end)
  end

  def request_spawn_txn(attempt_id, actor) do
    Txn.require_principal(actor, ["daemon", "boss"])
    attempt = fetch!(attempt_id)
    require_status!(attempt, "planned", "starting")
    attempt = Txn.update!(Attempt.changeset(attempt, %{status: "starting"}))
    Txn.append_event!("attempt.spawn_requested", "attempt", attempt.id)
    attempt
  end

  def mark_running(attempt_id, actor, attrs) do
    DatabaseWriter.transaction(fn -> mark_running_txn(attempt_id, actor, attrs) end)
  end

  def mark_running_txn(attempt_id, actor, attrs) do
    Txn.require_principal(actor, ["daemon"])
    attempt = fetch!(attempt_id)
    require_status!(attempt, "starting", "running")

    token = Map.fetch!(attrs, :fencing_token)

    if token != attempt.fencing_token do
      Txn.fenced(attempt.id)
    end

    runner_attrs =
      attrs
      |> Map.take([
        :invocation_id,
        :model,
        :reasoning_effort,
        :sandbox,
        :approval,
        :cli_version,
        :context_bytes,
        :context_input_tokens
      ])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    attempt =
      Txn.update!(
        Attempt.changeset(
          attempt,
          Map.merge(
            %{
              status: "running",
              runner_pid: Map.get(attrs, :runner_pid),
              harness_pid: Map.get(attrs, :harness_pid),
              pgid: Map.get(attrs, :pgid),
              started_at: Txn.now(),
              last_event_at: Txn.now()
            },
            runner_attrs
          )
        )
      )

    Txn.append_event!("attempt.started", "attempt", attempt.id)
    attempt
  end

  def mark_spawn_failed(attempt_id, actor, reason) do
    DatabaseWriter.transaction(fn -> mark_spawn_failed_txn(attempt_id, actor, reason) end)
  end

  def mark_spawn_failed_txn(attempt_id, actor, reason) do
    Txn.require_principal(actor, ["daemon"])
    attempt = fetch!(attempt_id)

    unless attempt.status in ["planned", "starting"] do
      Txn.illegal(attempt.status, "failed", :wrong_status)
    end

    Capabilities.revoke_for_attempt_txn(attempt.id)

    attempt =
      Txn.update!(
        Attempt.changeset(attempt, %{
          status: "failed",
          exit_classification: "spawn_failed",
          finished_at: Txn.now()
        })
      )

    DispatchOperations.release_slot_txn(attempt.id)

    Txn.append_event!("attempt.failed", "attempt", attempt.id, %{reason: reason})
    attempt
  end

  def touch_last_event(attempt_id, actor, at) do
    DatabaseWriter.transaction(fn -> touch_last_event_txn(attempt_id, actor, at) end)
  end

  def touch_last_event_txn(attempt_id, actor, at) do
    attempt = fetch!(attempt_id)
    require_fence!(actor, attempt)
    require_status!(attempt, "running", "running")
    Txn.update!(Attempt.changeset(attempt, %{last_event_at: at}))
  end

  def report_progress(attempt_id, actor, attrs \\ %{}) do
    DatabaseWriter.transaction(fn -> report_progress_txn(attempt_id, actor, attrs) end)
  end

  def report_progress_txn(attempt_id, actor, _attrs) do
    attempt = fetch!(attempt_id)
    require_fence!(actor, attempt)
    require_live_report!(attempt, "progress")
    attempt = Txn.update!(Attempt.changeset(attempt, %{last_event_at: Txn.now()}))
    Txn.append_event!("attempt.progress", "attempt", attempt.id, %{"accepted" => true})
    attempt
  end

  def report_completion(attempt_id, actor, attrs \\ %{}) do
    DatabaseWriter.transaction(fn -> report_completion_txn(attempt_id, actor, attrs) end)
  end

  def report_completion_txn(attempt_id, actor, attrs \\ %{}) do
    attempt = fetch!(attempt_id)
    require_fence!(actor, attempt)
    require_live_report!(attempt, "completion")
    _result = AttemptResults.capture_txn(attempt, actor, attrs, "completed")

    exit_classification =
      if attempt.exit_classification == "completed",
        do: "completed",
        else: "completion_reported"

    attempt =
      Txn.update!(
        Attempt.changeset(attempt, %{
          exit_classification: exit_classification,
          reported_checkpoint_sha: result_sha(attrs)
        })
      )

    Txn.append_event!("attempt.completion_reported", "attempt", attempt.id)
    attempt
  end

  def report_failure(attempt_id, actor, attrs \\ %{}) do
    DatabaseWriter.transaction(fn -> report_failure_txn(attempt_id, actor, attrs) end)
  end

  def report_failure_txn(attempt_id, actor, attrs) do
    attempt = fetch!(attempt_id)
    require_fence!(actor, attempt)
    require_live_report!(attempt, "failure")
    classification = failure_classification(attrs)
    attempt = Txn.update!(Attempt.changeset(attempt, %{exit_classification: classification}))

    Txn.append_event!("attempt.failure_reported", "attempt", attempt.id, %{
      "class" => classification
    })

    attempt
  end

  def request_checkpoint(attempt_id, actor, attrs \\ %{}) do
    DatabaseWriter.transaction(fn -> request_checkpoint_txn(attempt_id, actor, attrs) end)
  end

  def request_checkpoint_txn(attempt_id, actor, attrs) do
    attempt = fetch!(attempt_id)
    require_request_checkpoint_actor!(actor, attempt)
    require_status!(attempt, "running", "checkpoint_requested")

    strict? = actor.principal == "attempt" and not Map.get(attrs, :internal, false)

    if strict? or
         (not Map.get(attrs, :internal, false) and exact_checkpoint_report?(attempt, attrs)) do
      _result = AttemptResults.capture_txn(attempt, actor, attrs, "checkpoint", strict?)
    end

    attempt =
      Txn.update!(
        Attempt.changeset(attempt, %{
          status: "checkpoint_requested",
          reported_checkpoint_sha: result_sha(attrs)
        })
      )

    Txn.append_event!("attempt.checkpoint_requested", "attempt", attempt.id)
    attempt
  end

  def record_checkpointed(attempt_id, actor, attrs) do
    DatabaseWriter.transaction(fn -> record_checkpointed_txn(attempt_id, actor, attrs) end)
  end

  def record_checkpointed_txn(attempt_id, actor, attrs) do
    Txn.require_principal(actor, ["daemon", "boss"])
    attempt = fetch!(attempt_id)
    require_status!(attempt, "checkpoint_requested", "checkpointed")

    if Map.get(attrs, :process_group) != :dead_verified do
      Txn.illegal(attempt.status, "checkpointed", :death_not_verified)
    end

    Capabilities.revoke_for_attempt_txn(attempt.id)

    sha = Map.fetch!(attrs, :imported_sha)
    result = AttemptResults.by_attempt(attempt.id)

    if result &&
         (result.result_kind != "checkpoint" or result.reported_sha != sha or
            result.status != "imported" or Map.get(attrs, :result_ref) != result.result_ref) do
      Txn.illegal(attempt.status, "checkpointed", :result_not_imported)
    end

    attempt =
      Txn.update!(
        Attempt.changeset(attempt, %{
          status: "checkpointed",
          imported_sha: sha,
          result_ref: Map.get(attrs, :result_ref)
        })
      )

    mission = Repo.get!(Mission, attempt.mission_id)
    Txn.update!(Mission.changeset(mission, %{current_checkpoint_sha: sha}))

    if attempt.workspace_id do
      workspace = Repo.get!(Workspace, attempt.workspace_id)

      if workspace.status == "active" do
        Txn.update!(Workspace.changeset(workspace, %{status: "daemon_exclusive"}))
      end
    end

    Txn.append_event!("attempt.checkpointed", "attempt", attempt.id, %{imported_sha: sha})
    %{attempt: attempt, imported_sha: sha}
  end

  def complete(attempt_id, actor, attrs) do
    DatabaseWriter.transaction(fn -> complete_txn(attempt_id, actor, attrs) end)
  end

  def classify_exit(attempt_id, attrs) do
    DatabaseWriter.transaction(fn -> classify_exit_txn(attempt_id, attrs) end)
  end

  def classify_exit_txn(attempt_id, attrs) do
    attempt = fetch!(attempt_id)
    death = Map.get(attrs, :process_group, :dead_unverified)
    status = Map.get(attrs, :exit_status)
    completed? = Map.get(attrs, :session_completed, false)
    failed? = Map.get(attrs, :session_failed, false)
    klass = Map.get(attrs, :exit_classification)
    actor = Consigliere.Actor.system()

    cond do
      attempt.status in @terminal ->
        attempt

      attempt.status == "terminating" ->
        cancel_txn(attempt.id, actor, %{
          process_group: death,
          exit_classification: klass || attempt.exit_classification || "canceled"
        })

      protocol_missing_sha?(attempt, completed?, death) ->
        fail_txn(attempt.id, actor, %{
          process_group: death,
          exit_classification: "protocol_failure"
        })

      progress_after_death?(attempt, completed?, death, status) ->
        attempt

      completed? and death == :dead_verified and status in [0, nil] ->
        complete_txn(attempt.id, actor, %{process_group: death})

      failed? and death == :dead_verified ->
        fail_txn(attempt.id, actor, %{
          process_group: death,
          exit_classification: klass || "failed"
        })

      status == 0 and death == :dead_verified ->
        mark_lost_txn(attempt.id, actor, %{inventory: :dead_verified})

      death == :dead_verified ->
        fail_txn(attempt.id, actor, %{
          process_group: death,
          exit_classification: klass || "harness_exited"
        })

      true ->
        mark_lost_txn(attempt.id, actor, %{inventory: :unconfirmed})
    end
  end

  def complete_txn(attempt_id, actor, attrs) do
    Txn.require_principal(actor, ["daemon", "boss"])
    attempt = fetch!(attempt_id)

    unless attempt.status in ~w(running checkpoint_requested) do
      Txn.illegal(attempt.status, "completed", :wrong_status)
    end

    require_dead!(attempt, attrs, "completed")
    Capabilities.revoke_for_attempt_txn(attempt.id)

    sha = Map.get(attrs, :imported_sha)
    result = AttemptResults.by_attempt(attempt.id)

    unless (result && result.result_kind == "completed") and result.reported_sha == sha and
             result.status == "imported" and Map.get(attrs, :result_ref) == result.result_ref do
      Txn.illegal(attempt.status, "completed", :result_not_imported)
    end

    attempt =
      Txn.update!(
        Attempt.changeset(attempt, %{
          status: "completed",
          imported_sha: sha,
          result_ref: Map.get(attrs, :result_ref),
          finished_at: Txn.now()
        })
      )

    DispatchOperations.release_slot_txn(attempt.id)

    if sha do
      mission = Repo.get!(Mission, attempt.mission_id)
      Txn.update!(Mission.changeset(mission, %{current_checkpoint_sha: sha}))

      if attempt.workspace_id do
        workspace = Repo.get!(Workspace, attempt.workspace_id)

        if workspace.status == "active" do
          Txn.update!(Workspace.changeset(workspace, %{status: "daemon_exclusive"}))
        end
      end
    end

    Txn.append_event!("attempt.completed", "attempt", attempt.id)
    attempt
  end

  def fail(attempt_id, actor, attrs) do
    DatabaseWriter.transaction(fn -> fail_txn(attempt_id, actor, attrs) end)
  end

  def fail_txn(attempt_id, actor, attrs) do
    Txn.require_principal(actor, ["daemon", "boss"])
    attempt = fetch!(attempt_id)

    unless attempt.status in ~w(starting running terminating checkpoint_requested) do
      Txn.illegal(attempt.status, "failed", :wrong_status)
    end

    if attempt.status in ~w(running terminating checkpoint_requested) do
      require_dead!(attempt, attrs, "failed")
    end

    Capabilities.revoke_for_attempt_txn(attempt.id)

    attempt =
      Txn.update!(
        Attempt.changeset(attempt, %{
          status: "failed",
          exit_classification: Map.get(attrs, :exit_classification, "failed"),
          finished_at: Txn.now()
        })
      )

    DispatchOperations.release_slot_txn(attempt.id)

    Txn.append_event!("attempt.failed", "attempt", attempt.id)
    attempt
  end

  def cancel(attempt_id, actor, attrs) do
    DatabaseWriter.transaction(fn -> cancel_txn(attempt_id, actor, attrs) end)
  end

  def cancel_txn(attempt_id, actor, attrs) do
    Txn.require_principal(actor, ["boss", "daemon"])
    attempt = fetch!(attempt_id)
    refuse_terminal!(attempt, "canceled")
    require_dead!(attempt, attrs, "canceled")
    Capabilities.revoke_for_attempt_txn(attempt.id)

    attempt =
      Txn.update!(
        Attempt.changeset(attempt, %{
          status: "canceled",
          finished_at: Txn.now(),
          exit_classification: Map.get(attrs, :exit_classification, "canceled")
        })
      )

    DispatchOperations.release_slot_txn(attempt.id)

    Txn.append_event!("attempt.canceled", "attempt", attempt.id)
    attempt
  end

  def mark_lost(attempt_id, actor, attrs) do
    DatabaseWriter.transaction(fn -> mark_lost_txn(attempt_id, actor, attrs) end)
  end

  def mark_lost_txn(attempt_id, actor, attrs) do
    Txn.require_principal(actor, ["daemon"])
    attempt = fetch!(attempt_id)

    unless attempt.status in @lost_from do
      Txn.illegal(attempt.status, "lost", :wrong_status)
    end

    inventory = Map.fetch!(attrs, :inventory)
    Capabilities.revoke_for_attempt_txn(attempt.id)

    if attempt.workspace_id && inventory == :unconfirmed do
      workspace = Repo.get!(Workspace, attempt.workspace_id)

      Txn.update!(
        Workspace.changeset(workspace, %{
          status: "quarantined",
          quarantine_reason: "attempt_lost_unconfirmed"
        })
      )

      Txn.insert!(
        Incident.changeset(%Incident{}, %{
          mission_id: attempt.mission_id,
          subject_type: "attempt",
          subject_id: attempt.id,
          severity: "warning",
          reason: "attempt lost without confirmed process-group death"
        })
      )
    end

    attempt =
      Txn.update!(Attempt.changeset(attempt, %{status: "lost", finished_at: Txn.now()}))

    if inventory == :dead_verified do
      DispatchOperations.release_slot_txn(attempt.id)
    else
      DispatchOperations.hold_slot_txn(attempt.id)
    end

    Txn.append_event!("attempt.lost", "attempt", attempt.id, %{inventory: to_string(inventory)})
    attempt
  end

  def supersede(attempt_id, actor, replacement_attrs) do
    DatabaseWriter.transaction(fn -> supersede_txn(attempt_id, actor, replacement_attrs) end)
  end

  def supersede_txn(attempt_id, actor, replacement_attrs) do
    Txn.require_principal(actor, ["daemon", "boss"])
    attempt = fetch!(attempt_id)
    refuse_terminal!(attempt, "superseded")
    Capabilities.revoke_for_attempt_txn(attempt.id)

    replacement =
      schedule_txn(
        attempt.mission_id,
        actor,
        Map.merge(replacement_attrs, %{retry_of_attempt_id: attempt.id})
      )

    apply_question_rule!(attempt)
    attempt = Txn.update!(Attempt.changeset(attempt, %{status: "superseded"}))

    Txn.append_event!("attempt.superseded", "attempt", attempt.id, %{
      replacement_id: replacement.id
    })

    %{attempt: attempt, replacement: replacement}
  end

  defp protocol_missing_sha?(attempt, completed?, death) do
    death == :dead_verified and
      (completed? or attempt.status == "checkpoint_requested") and
      (not is_binary(attempt.reported_checkpoint_sha) or attempt.reported_checkpoint_sha == "")
  end

  defp result_sha(attrs) do
    Map.get(attrs, :result_sha) || Map.get(attrs, :reported_checkpoint_sha) ||
      Map.get(attrs, "result_sha") || Map.get(attrs, "reported_checkpoint_sha")
  end

  defp exact_checkpoint_report?(attempt, attrs) do
    sha = result_sha(attrs)
    base_sha = Map.get(attrs, :base_sha) || Map.get(attrs, "base_sha")

    is_binary(sha) and Consigliere.Git.valid_full_sha?(sha) and
      is_binary(base_sha) and Consigliere.Git.valid_full_sha?(base_sha) and
      is_binary(attempt.fencing_token)
  end

  defp progress_after_death?(attempt, completed?, death, status) do
    death == :dead_verified and
      status in [0, nil] and
      is_binary(attempt.reported_checkpoint_sha) and attempt.reported_checkpoint_sha != "" and
      (completed? or attempt.status == "checkpoint_requested" or
         attempt.exit_classification == "completion_reported")
  end

  defp fetch!(id) do
    case Repo.get(Attempt, id) do
      nil -> Txn.illegal(nil, nil, :not_found)
      attempt -> attempt
    end
  end

  defp fetch_mission!(id) do
    case Repo.get(Mission, id) do
      nil -> Txn.illegal(nil, nil, :not_found)
      mission -> mission
    end
  end

  defp require_status!(attempt, from, to) do
    if attempt.status == from, do: :ok, else: Txn.illegal(attempt.status, to, :wrong_status)
  end

  defp refuse_terminal!(attempt, to) do
    if attempt.status in @terminal, do: Txn.illegal(attempt.status, to, :terminal)
  end

  defp require_dead!(attempt, attrs, to) do
    if Map.get(attrs, :process_group) != :dead_verified do
      Txn.illegal(attempt.status, to, :death_not_verified)
    end
  end

  defp require_fence!(actor, attempt) do
    cond do
      actor.principal != "attempt" ->
        Txn.unauthorized(:principal)

      actor.attempt_id != attempt.id ->
        Txn.fenced(attempt.id)

      actor.fencing_token != attempt.fencing_token ->
        Txn.fenced(attempt.id)

      attempt.status in @terminal ->
        Txn.fenced(attempt.id)

      true ->
        case Capabilities.revalidate_actor(actor, attempt) do
          :ok -> :ok
          {:error, reason} -> Txn.unauthorized(reason)
        end
    end
  end

  defp require_live_report!(attempt, report) do
    unless attempt.status in ~w(running checkpoint_requested) do
      Txn.illegal(attempt.status, report, :attempt_not_live)
    end
  end

  defp failure_classification(%{classification: classification})
       when classification in ["failed", "protocol_failure", "harness_failed", "canceled"],
       do: classification

  defp failure_classification(_), do: "failed"

  defp require_request_checkpoint_actor!(actor, attempt) do
    case actor.principal do
      "daemon" -> :ok
      "boss" -> :ok
      "attempt" -> require_fence!(actor, attempt)
      _ -> Txn.unauthorized(:principal)
    end
  end

  defp apply_question_rule!(attempt) do
    from(q in Question,
      where: q.attempt_id == ^attempt.id and q.status in ["open", "routed"]
    )
    |> Repo.all()
    |> Enum.each(fn question ->
      if question.blocking_scope == "attempt" do
        Txn.update!(Question.changeset(question, %{status: "superseded"}))
        Txn.append_event!("question.superseded", "question", question.id)
        close_question_blocker!(question, "superseded")
      end
    end)
  end

  defp close_question_blocker!(question, reason) do
    from(b in MissionBlocker,
      where:
        b.mission_id == ^question.mission_id and b.kind == "question" and b.status == "open" and
          b.subject_id == ^question.id
    )
    |> Repo.all()
    |> Enum.each(fn blocker ->
      Txn.update!(
        MissionBlocker.changeset(blocker, %{
          status: "closed",
          closed_reason: reason,
          closed_at: Txn.now()
        })
      )
    end)
  end
end
