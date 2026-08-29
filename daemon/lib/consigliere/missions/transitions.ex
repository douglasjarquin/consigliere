defmodule Consigliere.Missions.Transitions do
  @moduledoc false

  import Ecto.Query

  alias Consigliere.DatabaseWriter
  alias Consigliere.Repo
  alias Consigliere.Txn
  alias Consigliere.Missions.Mission
  alias Consigliere.Authorizations.Authorization
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Questions.Question
  alias Consigliere.Gates.Gate
  alias Consigliere.MissionBlockers.MissionBlocker
  alias Consigliere.Decisions.Decision
  alias Consigliere.Incidents.Incident
  alias Consigliere.DispatchOperations
  alias Consigliere.Projects.Project
  alias Consigliere.Workspaces.Workspace

  @hard_terminal ~w(completed canceled superseded)
  @edit_principals ~w(boss model_advisory daemon)
  @start_principals ~w(boss daemon)

  def create(attrs, actor) do
    DatabaseWriter.transaction(fn -> create_txn(attrs, actor) end)
  end

  def create_txn(attrs, actor) do
    Txn.require_principal(actor, @edit_principals)

    project_id = Map.get(attrs, :project_id) || Map.get(attrs, "project_id")

    unless is_binary(project_id) and project_id != "" do
      Txn.illegal(nil, "draft", :project_required)
    end

    attrs = Map.put_new(attrs, :phase, "draft")
    mission = Txn.insert!(Mission.changeset(%Mission{}, attrs))
    Txn.append_event!("mission.created", "mission", mission.id)
    mission
  end

  def submit_for_authorization(mission_id, actor) do
    DatabaseWriter.transaction(fn -> submit_for_authorization_txn(mission_id, actor) end)
  end

  def submit_for_authorization_txn(mission_id, actor) do
    Txn.require_principal(actor, @edit_principals)
    mission = fetch_mission!(mission_id)
    require_phase!(mission, "draft", "awaiting_authorization")

    if blank?(mission.objective) or blank?(mission.scope) or blank?(mission.acceptance_criteria) do
      Txn.illegal(mission.phase, "awaiting_authorization", :incomplete)
    end

    mission = Txn.update!(Mission.changeset(mission, %{phase: "awaiting_authorization"}))
    Txn.append_event!("mission.submitted", "mission", mission.id)
    mission
  end

  def request_changes(mission_id, actor, reason \\ nil) do
    DatabaseWriter.transaction(fn -> request_changes_txn(mission_id, actor, reason) end)
  end

  def request_changes_txn(mission_id, actor, reason \\ nil) do
    Txn.require_principal(actor, @edit_principals)
    mission = fetch_mission!(mission_id)
    require_phase!(mission, "awaiting_authorization", "draft")
    mission = Txn.update!(Mission.changeset(mission, %{phase: "draft"}))
    payload = if is_binary(reason) and reason != "", do: %{reason: reason}, else: %{}
    Txn.append_event!("mission.returned_to_draft", "mission", mission.id, payload)
    mission
  end

  def grant_work_authorization(mission_id, actor, attrs \\ %{}) do
    DatabaseWriter.transaction(fn -> grant_work_authorization_txn(mission_id, actor, attrs) end)
  end

  def grant_work_authorization_txn(mission_id, actor, attrs) do
    Txn.require_principal(actor, ["boss"])
    mission = fetch_mission!(mission_id)
    require_phase!(mission, "awaiting_authorization", "authorized")

    auth =
      Txn.insert!(
        Authorization.changeset(%Authorization{}, %{
          mission_id: mission.id,
          scope: "work",
          granted_by_principal: actor.principal,
          granted_at: Txn.now(),
          expires_at: Map.get(attrs, :expires_at)
        })
      )

    mission =
      Txn.update!(
        Mission.changeset(mission, %{
          phase: "authorized",
          authorization_id: auth.id,
          base_sha: Map.get(attrs, :base_sha, mission.base_sha)
        })
      )

    Txn.append_event!("mission.authorized", "mission", mission.id, %{authorization_id: auth.id})
    mission
  end

  def grant_work_authorization_with_dispatch_txn(mission_id, actor, attrs) do
    existing_mission = fetch_mission!(mission_id)

    if project_has_active_mission?(existing_mission) do
      Txn.illegal(existing_mission.phase, "authorized", :project_busy)
    end

    mission = grant_work_authorization_txn(mission_id, actor, attrs)

    workspace =
      Txn.insert!(
        Workspace.changeset(%Workspace{}, %{
          mission_id: mission.id,
          path: Path.join(Consigliere.Home.workspaces_dir(), mission.id),
          lease_id: Txn.mint_fencing_token(),
          fencing_token: Txn.mint_fencing_token(),
          status: "active",
          project_id: mission.project_id,
          base_sha: mission.base_sha,
          parent_checkpoint_sha: mission.current_checkpoint_sha
        })
      )

    attempt =
      Txn.insert!(
        Attempt.changeset(%Attempt{}, %{
          mission_id: mission.id,
          workspace_id: workspace.id,
          role: "soldier",
          harness: Consigliere.Adapters.harness().capabilities()["harness_name"],
          status: "planned",
          fencing_token: Txn.mint_fencing_token()
        })
      )

    operation =
      DispatchOperations.ensure_txn(attempt, %{
        status: "pending",
        slot_state: "pending",
        correlation_id: Map.get(attrs, :correlation_id),
        idempotency_key: Map.get(attrs, :idempotency_key),
        authorization_id: mission.authorization_id,
        project_id: mission.project_id,
        workspace_generation: workspace.lease_id,
        base_sha: mission.base_sha,
        parent_checkpoint_sha: mission.current_checkpoint_sha
      })

    Txn.append_event!("mission.dispatch_requested", "mission", mission.id, %{
      authorization_id: mission.authorization_id,
      dispatch_operation_id: operation.id,
      attempt_id: attempt.id,
      workspace_id: workspace.id
    })

    mission
  end

  defp project_has_active_mission?(%Mission{project_id: nil}), do: false

  defp project_has_active_mission?(%Mission{project_id: project_id, id: mission_id}) do
    active_phases =
      ~w(authorized active paused ready_for_review awaiting_integration_authorization integrating)

    Repo.exists?(
      from(m in Mission,
        where:
          m.project_id == ^project_id and m.id != ^mission_id and
            m.phase in ^active_phases
      )
    )
  end

  def start(mission_id, actor, opts) do
    DatabaseWriter.transaction(fn -> start_txn(mission_id, actor, opts) end)
  end

  def activate_dispatch(mission_id, actor, attempt_id, workspace_id) do
    DatabaseWriter.transaction(fn ->
      activate_dispatch_txn(mission_id, actor, attempt_id, workspace_id)
    end)
  end

  def activate_dispatch_txn(mission_id, actor, attempt_id, workspace_id) do
    Txn.require_principal(actor, @start_principals)
    mission = fetch_mission!(mission_id)
    attempt = Repo.get(Attempt, attempt_id)
    workspace = Repo.get(Workspace, workspace_id)

    unless match?(%Attempt{mission_id: ^mission_id, workspace_id: ^workspace_id}, attempt) do
      Txn.illegal(mission.phase, "active", :attempt_identity_mismatch)
    end

    unless match?(%Workspace{mission_id: ^mission_id, status: "active"}, workspace) do
      Txn.illegal(mission.phase, "active", :workspace_identity_mismatch)
    end

    case mission.phase do
      "authorized" ->
        mission =
          Txn.update!(Mission.changeset(mission, %{phase: "active", started_at: Txn.now()}))

        Txn.append_event!("mission.started", "mission", mission.id, %{
          attempt_id: attempt.id,
          workspace_id: workspace.id
        })

        mission

      "active" ->
        mission

      phase ->
        Txn.illegal(phase, "active", :mission_not_authorized)
    end
  end

  def start_txn(mission_id, actor, opts) do
    Txn.require_principal(actor, @start_principals)
    mission = fetch_mission!(mission_id)
    require_phase!(mission, "authorized", "active")
    project = mission.project_id && Repo.get(Project, mission.project_id)
    workspace_path = Map.fetch!(opts, :workspace_path)

    if Consigliere.Projects.trusted_identity?(project) and
         not Consigliere.Projects.workspace_path_shape?(workspace_path, mission.id) do
      Txn.illegal(mission.phase, "active", :workspace_path_invalid)
    end

    workspace =
      Txn.insert!(
        Workspace.changeset(%Workspace{}, %{
          mission_id: mission.id,
          path: workspace_path,
          lease_id: Map.get(opts, :lease_id, "lease-#{Txn.mint_fencing_token()}"),
          fencing_token: Map.get(opts, :workspace_fencing_token, Txn.mint_fencing_token()),
          status: "active",
          project_id: mission.project_id,
          base_sha: mission.base_sha,
          parent_checkpoint_sha: mission.current_checkpoint_sha
        })
      )

    attempt =
      Txn.insert!(
        Attempt.changeset(%Attempt{}, %{
          mission_id: mission.id,
          workspace_id: workspace.id,
          role: Map.get(opts, :role, "soldier"),
          harness:
            Map.get(opts, :harness, Consigliere.Adapters.harness().capabilities()["harness_name"]),
          status: "planned",
          fencing_token: Txn.mint_fencing_token()
        })
      )

    mission =
      Txn.update!(Mission.changeset(mission, %{phase: "active", started_at: Txn.now()}))

    Txn.append_event!("mission.started", "mission", mission.id, %{
      attempt_id: attempt.id,
      workspace_id: workspace.id
    })

    %{mission: mission, workspace: workspace, attempt: attempt}
  end

  def mark_ready_for_review(mission_id, actor) do
    DatabaseWriter.transaction(fn -> mark_ready_for_review_txn(mission_id, actor) end)
  end

  def mark_ready_for_review_txn(mission_id, actor) do
    Txn.require_principal(actor, @start_principals)
    mission = fetch_mission!(mission_id)
    require_phase!(mission, "active", "ready_for_review")

    required = required_gate_types(mission)

    if mission.current_checkpoint_sha in [nil, ""] do
      Txn.illegal(mission.phase, "ready_for_review", :missing_checkpoint)
    end

    Enum.each(required, fn gate_type ->
      unless passed_gate?(mission, gate_type) do
        Txn.illegal(mission.phase, "ready_for_review", {:gate_not_passed, gate_type})
      end
    end)

    mission = Txn.update!(Mission.changeset(mission, %{phase: "ready_for_review"}))
    Txn.append_event!("mission.ready_for_review", "mission", mission.id)
    mission
  end

  def return_to_active(mission_id, actor, reason) do
    DatabaseWriter.transaction(fn -> return_to_active_txn(mission_id, actor, reason) end)
  end

  def return_to_active_txn(mission_id, actor, reason) do
    Txn.require_principal(actor, @start_principals)
    mission = fetch_mission!(mission_id)

    unless mission.phase in ~w(ready_for_review awaiting_integration_authorization) do
      Txn.illegal(mission.phase, "active", :wrong_phase)
    end

    if mission.phase == "awaiting_integration_authorization" do
      revoke_open_authorizations!(mission, "integration")
      open_blocker!(mission, "external_service", reason)
    end

    mission = Txn.update!(Mission.changeset(mission, %{phase: "active"}))
    mission
  end

  def await_integration_authorization(mission_id, actor, attrs) do
    DatabaseWriter.transaction(fn ->
      await_integration_authorization_txn(mission_id, actor, attrs)
    end)
  end

  def await_integration_authorization_txn(mission_id, actor, attrs) do
    Txn.require_principal(actor, @start_principals)
    mission = fetch_mission!(mission_id)
    require_phase!(mission, "ready_for_review", "awaiting_integration_authorization")
    sha = Map.fetch!(attrs, :delivery_sha)

    mission =
      Txn.update!(
        Mission.changeset(mission, %{
          phase: "awaiting_integration_authorization",
          current_delivery_sha: sha
        })
      )

    Txn.append_event!("mission.awaiting_integration", "mission", mission.id, %{delivery_sha: sha})
    mission
  end

  def grant_integration_authorization(mission_id, actor, attrs) do
    DatabaseWriter.transaction(fn ->
      grant_integration_authorization_txn(mission_id, actor, attrs)
    end)
  end

  def grant_integration_authorization_txn(mission_id, actor, attrs) do
    Txn.require_principal(actor, ["boss"])
    mission = fetch_mission!(mission_id)
    require_phase!(mission, "awaiting_integration_authorization", "integrating")

    target_sha = Map.fetch!(attrs, :target_sha)
    pr = Map.fetch!(attrs, :target_pull_request)

    if target_sha != mission.current_delivery_sha do
      Txn.illegal(mission.phase, "integrating", :target_sha_mismatch)
    end

    auth =
      Txn.insert!(
        Authorization.changeset(%Authorization{}, %{
          mission_id: mission.id,
          scope: "integration",
          granted_by_principal: "boss",
          granted_at: Txn.now(),
          target_pull_request: pr,
          target_sha: target_sha
        })
      )

    mission =
      Txn.update!(Mission.changeset(mission, %{phase: "integrating", authorization_id: auth.id}))

    Txn.append_event!("mission.integration_authorized", "mission", mission.id, %{
      authorization_id: auth.id
    })

    mission
  end

  def complete_integration(mission_id, actor, attrs) do
    DatabaseWriter.transaction(fn -> complete_integration_txn(mission_id, actor, attrs) end)
  end

  def complete_integration_txn(mission_id, actor, attrs) do
    Txn.require_principal(actor, @start_principals)
    mission = fetch_mission!(mission_id)
    require_phase!(mission, "integrating", "completed")
    merged_sha = Map.fetch!(attrs, :merged_sha)

    consume_authorization!(mission)

    mission =
      Txn.update!(
        Mission.changeset(mission, %{
          phase: "completed",
          completed_at: Txn.now(),
          current_delivery_sha: merged_sha
        })
      )

    Txn.append_event!("mission.completed", "mission", mission.id, %{merged_sha: merged_sha})
    mission
  end

  def detect_integration_race(mission_id, actor, reason) do
    DatabaseWriter.transaction(fn -> detect_integration_race_txn(mission_id, actor, reason) end)
  end

  def detect_integration_race_txn(mission_id, actor, reason) do
    Txn.require_principal(actor, @start_principals)
    mission = fetch_mission!(mission_id)
    require_phase!(mission, "integrating", "awaiting_integration_authorization")
    revoke_open_authorizations!(mission, "integration")
    open_blocker!(mission, "external_service", reason)

    mission =
      Txn.update!(Mission.changeset(mission, %{phase: "awaiting_integration_authorization"}))

    Txn.append_event!("mission.integration_race_detected", "mission", mission.id, %{
      reason: reason
    })

    mission
  end

  def fail(mission_id, actor, attrs) do
    DatabaseWriter.transaction(fn -> fail_txn(mission_id, actor, attrs) end)
  end

  def fail_txn(mission_id, actor, attrs) do
    Txn.require_principal(actor, @start_principals)
    mission = fetch_mission!(mission_id)
    refuse_hard_terminal!(mission, "failed")
    reason = Map.fetch!(attrs, :terminal_reason)

    if incident_attrs = Map.get(attrs, :incident_attrs) do
      Txn.insert!(
        Incident.changeset(%Incident{}, Map.merge(%{mission_id: mission.id}, incident_attrs))
      )
    end

    handle_open_questions_on_mission_end!(mission)
    Consigliere.Termination.request_live_attempts!(mission, "failed")
    cancel_inflight_gates!(mission)

    mission =
      Txn.update!(Mission.changeset(mission, %{phase: "failed", terminal_reason: reason}))

    Txn.append_event!("mission.failed", "mission", mission.id, %{terminal_reason: reason})
    mission
  end

  def pause(mission_id, actor, reason \\ "boss pause") do
    DatabaseWriter.transaction(fn -> pause_txn(mission_id, actor, reason) end)
  end

  def pause_txn(mission_id, actor, reason) do
    Txn.require_principal(actor, ["boss"])
    mission = fetch_mission!(mission_id)

    cond do
      mission.phase == "paused" ->
        mission

      mission.phase in @hard_terminal ->
        Txn.illegal(mission.phase, "paused", :terminal)

      open_blocker_kind?(mission, ["pausing"]) ->
        mission

      true ->
        revoke_and_fence!(mission)
        Consigliere.Termination.request_live_attempts!(mission, "paused")
        open_blocker!(mission, "pausing", reason)
        Txn.append_event!("mission.pause_requested", "mission", mission.id, %{reason: reason})
        mission
    end
  end

  def resume(mission_id, actor) do
    DatabaseWriter.transaction(fn -> resume_txn(mission_id, actor) end)
  end

  def resume_txn(mission_id, actor) do
    Txn.require_principal(actor, ["boss"])
    mission = fetch_mission!(mission_id)

    cond do
      mission.phase == "paused" or open_blocker_kind?(mission, ["paused"]) ->
        close_pause_blockers!(mission)
        mission = Txn.update!(Mission.changeset(mission, %{phase: "authorized"}))
        Txn.append_event!("mission.resumed", "mission", mission.id)
        mission

      open_blocker_kind?(mission, ["pausing"]) ->
        Txn.illegal(mission.phase, "authorized", :cleanup_pending)

      mission.phase == "authorized" ->
        mission

      true ->
        Txn.illegal(mission.phase, "authorized", :not_paused)
    end
  end

  def cancel(mission_id, actor, reason) do
    DatabaseWriter.transaction(fn -> cancel_txn(mission_id, actor, reason) end)
  end

  def cancel_txn(mission_id, actor, reason) do
    Txn.require_principal(actor, ["boss"])
    mission = fetch_mission!(mission_id)
    refuse_hard_terminal!(mission, "canceled")
    handle_open_questions_on_mission_end!(mission)
    Consigliere.Termination.request_live_attempts!(mission, "canceled")
    cancel_inflight_gates!(mission)
    close_open_blockers!(mission, "withdrawn")

    mission =
      Txn.update!(Mission.changeset(mission, %{phase: "canceled", terminal_reason: reason}))

    Txn.append_event!("mission.canceled", "mission", mission.id, %{reason: reason})
    mission
  end

  def supersede(mission_id, actor, replacement_attrs) do
    DatabaseWriter.transaction(fn -> supersede_txn(mission_id, actor, replacement_attrs) end)
  end

  def supersede_txn(mission_id, actor, replacement_attrs) do
    Txn.require_principal(actor, ["boss", "daemon"])
    mission = fetch_mission!(mission_id)
    refuse_hard_terminal!(mission, "superseded")

    replacement =
      create_txn(
        Map.merge(replacement_attrs, %{replaces_mission_id: mission.id}),
        actor
      )

    handle_open_questions_on_mission_end!(mission)
    Consigliere.Termination.request_live_attempts!(mission, "superseded")
    cancel_inflight_gates!(mission)
    close_open_blockers!(mission, "superseded")

    mission = Txn.update!(Mission.changeset(mission, %{phase: "superseded"}))

    Txn.append_event!("mission.superseded", "mission", mission.id, %{
      replacement_id: replacement.id
    })

    %{mission: mission, replacement: replacement}
  end

  def resume_after_decision(mission_id, actor, decision_id) do
    DatabaseWriter.transaction(fn ->
      resume_after_decision_txn(mission_id, actor, decision_id)
    end)
  end

  def resume_after_decision_txn(mission_id, actor, decision_id) do
    Txn.require_principal(actor, ["boss", "daemon"])
    mission = fetch_mission!(mission_id)
    require_phase!(mission, "failed", "active")

    decision =
      case Repo.get(Decision, decision_id) do
        nil -> Txn.illegal(mission.phase, "active", :decision_not_found)
        d -> d
      end

    unless decision.scope in ~w(mission_finding_waiver project_policy_override) do
      Txn.illegal(mission.phase, "active", :wrong_decision_scope)
    end

    if decision.revoked_at, do: Txn.illegal(mission.phase, "active", :decision_revoked)

    if decision.mission_id && decision.mission_id != mission.id do
      Txn.illegal(mission.phase, "active", :decision_wrong_mission)
    end

    mission = Txn.update!(Mission.changeset(mission, %{phase: "active", terminal_reason: nil}))

    Txn.append_event!("mission.resumed_after_decision", "mission", mission.id, %{
      decision_id: decision.id
    })

    mission
  end

  defp fetch_mission!(id) do
    case Repo.get(Mission, id) do
      nil -> Txn.illegal(nil, nil, :not_found)
      mission -> mission
    end
  end

  defp require_phase!(mission, from, to) when is_binary(from) do
    if mission.phase == from, do: :ok, else: Txn.illegal(mission.phase, to, :wrong_phase)
  end

  defp refuse_hard_terminal!(mission, to) do
    if mission.phase in @hard_terminal, do: Txn.illegal(mission.phase, to, :terminal)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  def required_gate_types(mission) do
    case mission.validation_policy do
      %{"required_gate_types" => types} when is_list(types) and types != [] -> types
      _ -> ["review"]
    end
  end

  defp passed_gate?(mission, gate_type) do
    Repo.exists?(
      from(g in Gate,
        where:
          g.mission_id == ^mission.id and g.gate_type == ^gate_type and g.status == "passed" and
            g.input_sha == ^mission.current_checkpoint_sha
      )
    )
  end

  defp revoke_open_authorizations!(mission, scope) do
    from(a in Authorization,
      where: a.mission_id == ^mission.id and a.scope == ^scope and is_nil(a.revoked_at)
    )
    |> Repo.all()
    |> Enum.each(fn auth ->
      Txn.update!(Authorization.changeset(auth, %{revoked_at: Txn.now()}))
    end)
  end

  defp consume_authorization!(mission) do
    if mission.authorization_id do
      case Repo.get(Authorization, mission.authorization_id) do
        nil -> :ok
        auth -> Txn.update!(Authorization.changeset(auth, %{consumed_at: Txn.now()}))
      end
    end
  end

  defp revoke_and_fence!(mission) do
    live = ~w(planned starting running checkpoint_requested terminating)

    from(a in Attempt, where: a.mission_id == ^mission.id and a.status in ^live)
    |> Repo.all()
    |> Enum.each(fn attempt ->
      Consigliere.Capabilities.revoke_for_attempt_txn(attempt.id)
      Txn.update!(Attempt.changeset(attempt, %{fencing_token: Txn.mint_fencing_token()}))
    end)
  end

  defp open_blocker_kind?(mission, kinds) do
    Repo.exists?(
      from(b in MissionBlocker,
        where: b.mission_id == ^mission.id and b.kind in ^kinds and b.status == "open"
      )
    )
  end

  defp close_pause_blockers!(mission) do
    from(b in MissionBlocker,
      where:
        b.mission_id == ^mission.id and b.kind in ["paused", "pausing"] and b.status == "open"
    )
    |> Repo.all()
    |> Enum.each(fn blocker ->
      Txn.update!(
        MissionBlocker.changeset(blocker, %{
          status: "closed",
          closed_reason: "boss resume",
          closed_at: Txn.now()
        })
      )
    end)
  end

  defp open_blocker!(mission, kind, reason) do
    Txn.insert!(
      MissionBlocker.changeset(%MissionBlocker{}, %{
        mission_id: mission.id,
        kind: kind,
        reason: reason,
        status: "open"
      })
    )
  end

  defp close_open_blockers!(mission, closed_reason) do
    from(b in MissionBlocker, where: b.mission_id == ^mission.id and b.status == "open")
    |> Repo.all()
    |> Enum.each(fn blocker ->
      Txn.update!(
        MissionBlocker.changeset(blocker, %{
          status: "closed",
          closed_reason: closed_reason,
          closed_at: Txn.now()
        })
      )
    end)
  end

  defp handle_open_questions_on_mission_end!(mission) do
    from(q in Question, where: q.mission_id == ^mission.id and q.status in ["open", "routed"])
    |> Repo.all()
    |> Enum.each(fn question ->
      Txn.update!(Question.changeset(question, %{status: "withdrawn"}))
      Txn.append_event!("question.withdrawn", "question", question.id)

      from(b in MissionBlocker,
        where:
          b.mission_id == ^mission.id and b.kind == "question" and b.status == "open" and
            b.subject_id == ^question.id
      )
      |> Repo.all()
      |> Enum.each(fn blocker ->
        Txn.update!(
          MissionBlocker.changeset(blocker, %{
            status: "closed",
            closed_reason: "withdrawn",
            closed_at: Txn.now()
          })
        )
      end)
    end)
  end

  defp cancel_inflight_gates!(mission) do
    from(g in Gate, where: g.mission_id == ^mission.id and g.status in ["pending", "running"])
    |> Repo.all()
    |> Enum.each(fn gate ->
      Txn.update!(Gate.changeset(gate, %{status: "canceled"}))
      Txn.append_event!("gate.canceled", "gate", gate.id)
    end)
  end
end
