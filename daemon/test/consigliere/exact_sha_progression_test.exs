defmodule Consigliere.ExactSHAProgressionTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Attempts.Attempt
  alias Consigliere.AttemptResults.AttemptResult
  alias Consigliere.Fixtures
  alias Consigliere.Gates.Gate
  alias Consigliere.Git
  alias Consigliere.Harness.Events
  alias Consigliere.Home
  alias Consigliere.Missions
  alias Consigliere.Missions.Mission
  alias Consigliere.ProjectVerifications.VerificationRun
  alias Consigliere.Projects
  alias Consigliere.Repo

  setup do
    Fixtures.reset_phase1_tables!()
    Consigliere.GlobalScheduler.reset()

    root = Path.join(System.tmp_dir!(), "cs-exact-sha-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source")
    File.mkdir_p!(root)
    Git.init_workspace(source)
    File.write!(Path.join(source, "README"), "base\n")
    base_sha = Git.commit_all(source, "base")

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, source: source, base_sha: base_sha}
  end

  test "a completion requires exact bound identity and imports only after verified death", %{
    root: root,
    source: source,
    base_sha: base_sha
  } do
    %{project: project, mission: mission, attempt: attempt, workspace: workspace} =
      running_project_attempt!(source, base_sha)

    File.write!(Path.join(workspace.path, "result.txt"), "result\n")
    result_sha = Git.commit_all(workspace.path, "result")
    record_terminal_event!(attempt, 7)
    {secret, _capability} = mint_capability!(attempt)

    assert {:ok, _} =
             complete_via_protocol(
               secret,
               attempt,
               mission,
               workspace,
               result_sha,
               7
             )

    result = Repo.get_by!(AttemptResult, attempt_id: attempt.id)
    assert result.reported_sha == result_sha
    assert result.mission_id == mission.id
    assert result.project_id == project.id
    assert result.workspace_id == workspace.id
    assert result.workspace_generation == workspace.lease_id
    assert result.base_sha == base_sha
    assert result.parent_checkpoint_sha == nil
    assert result.fencing_generation == attempt.fencing_token
    assert result.accepted_terminal_sequence == 7
    assert result.result_kind == "completed"

    assert {:error, _} =
             complete_via_protocol(
               secret,
               attempt,
               mission,
               workspace,
               String.duplicate("f", 40),
               7
             )

    assert {:error, :death_not_verified} = Consigliere.Progression.run(attempt.id)

    assert {:error, _} =
             Git.read_ref(project.trusted_mirror_path, Git.result_ref(project.id, attempt.id))

    assert Repo.get!(Mission, mission.id).current_checkpoint_sha == nil

    assert {:ok, _} =
             Consigliere.Progression.run(
               attempt.id,
               process_group: :dead_verified,
               command_timeout_ms: 2_000,
               total_timeout_ms: 5_000
             )

    assert {:ok, ^result_sha} =
             Git.read_ref(project.trusted_mirror_path, Git.result_ref(project.id, attempt.id))

    assert Repo.get!(Attempt, attempt.id).imported_sha == result_sha
    assert Repo.get!(Mission, mission.id).current_checkpoint_sha == result_sha
    assert Repo.get!(Mission, mission.id).phase == "ready_for_review"
    assert Repo.get_by!(Gate, mission_id: mission.id, input_sha: result_sha).status == "passed"
    assert Repo.get_by!(VerificationRun, attempt_id: attempt.id).outcome == "passed"

    refute File.exists?(Path.join(root, "unexpected-delivery"))
  end

  test "latest completion reports bind the later native terminal event", %{
    source: source,
    base_sha: base_sha
  } do
    %{project: project, mission: mission, attempt: attempt, workspace: workspace} =
      running_project_attempt!(source, base_sha)

    File.write!(Path.join(workspace.path, "result.txt"), "result\n")
    result_sha = Git.commit_all(workspace.path, "result")
    record_checkpoint_event!(attempt, result_sha, 7)
    {secret, _capability} = mint_capability!(attempt)

    assert {:ok, _} =
             complete_via_protocol(
               secret,
               attempt,
               mission,
               workspace,
               result_sha,
               "latest"
             )

    assert Repo.get_by!(AttemptResult, attempt_id: attempt.id).accepted_terminal_sequence == 7
    record_terminal_event!(attempt, 8)

    assert {:error, _} =
             complete_via_protocol(
               secret,
               attempt,
               mission,
               workspace,
               result_sha,
               8
             )

    assert {:ok, _} =
             Consigliere.Progression.run(
               attempt.id,
               process_group: :dead_verified,
               command_timeout_ms: 2_000,
               total_timeout_ms: 5_000
             )

    result = Repo.get_by!(AttemptResult, attempt_id: attempt.id)
    assert result.accepted_terminal_sequence == 8
    assert result.reported_sha == result_sha
    assert Repo.get!(Attempt, attempt.id).status == "completed"
    assert Repo.get!(Mission, mission.id).phase == "ready_for_review"

    assert {:ok, ^result_sha} =
             Git.read_ref(project.trusted_mirror_path, Git.result_ref(project.id, attempt.id))
  end

  test "identity, ancestry, configuration, and verification failures remain explainable", %{
    source: source,
    base_sha: base_sha
  } do
    %{project: project, mission: mission, attempt: attempt, workspace: workspace} =
      running_project_attempt!(source, base_sha)

    File.write!(Path.join(workspace.path, "result.txt"), "result\n")
    result_sha = Git.commit_all(workspace.path, "result")
    record_terminal_event!(attempt, 8)
    {secret, _capability} = mint_capability!(attempt)

    assert {:error, _} =
             complete_via_protocol(
               secret,
               attempt,
               mission,
               workspace,
               String.slice(result_sha, 0, 39),
               8
             )

    assert {:ok, _} =
             complete_via_protocol(
               secret,
               attempt,
               mission,
               workspace,
               result_sha,
               8
             )

    {:ok, _} =
      Repo.update(
        Consigliere.Workspaces.Workspace.changeset(workspace, %{lease_id: "stale-lease"})
      )

    assert {:error, _} =
             Consigliere.Progression.run(
               attempt.id,
               process_group: :dead_verified,
               command_timeout_ms: 2_000,
               total_timeout_ms: 5_000
             )

    failed = Repo.get_by!(AttemptResult, attempt_id: attempt.id)
    assert failed.status == "failed"
    assert failed.failure_code == "workspace_generation_mismatch"
    assert Repo.get!(Mission, mission.id).phase == "active"
    refute Git.mirror_has_commit?(project.trusted_mirror_path, result_sha)
  end

  test "checkpoint continuation creates one fresh bound Attempt from the imported SHA", %{
    source: source,
    base_sha: base_sha
  } do
    %{mission: mission, attempt: attempt, workspace: workspace} =
      running_project_attempt!(source, base_sha)

    File.write!(Path.join(workspace.path, "checkpoint.txt"), "checkpoint\n")
    checkpoint_sha = Git.commit_all(workspace.path, "checkpoint")
    record_checkpoint_event!(attempt, checkpoint_sha, 9)
    {secret, _capability} = mint_capability!(attempt)

    assert {:ok, _} =
             checkpoint_via_protocol(
               secret,
               attempt,
               mission,
               workspace,
               checkpoint_sha,
               9
             )

    assert {:ok, _} =
             Consigliere.Progression.run(
               attempt.id,
               process_group: :dead_verified,
               command_timeout_ms: 2_000,
               total_timeout_ms: 5_000
             )

    assert Repo.get!(Attempt, attempt.id).status == "checkpointed"
    assert Repo.get!(Mission, mission.id).current_checkpoint_sha == checkpoint_sha
    assert Repo.get!(Mission, mission.id).phase == "active"

    assert {:ok, %{mission: continued, attempt: fresh, workspace: fresh_workspace}} =
             Missions.continue_from_checkpoint(mission.id, Actor.boss(), checkpoint_sha)

    assert continued.id == mission.id
    assert fresh.id != attempt.id
    assert fresh.retry_of_attempt_id == attempt.id
    assert fresh.fencing_token != attempt.fencing_token
    assert fresh.workspace_id == fresh_workspace.id
    assert fresh_workspace.parent_checkpoint_sha == checkpoint_sha
    assert fresh_workspace.lease_id != workspace.lease_id
    assert Repo.aggregate(Attempt, :count) == 2

    assert {:error, {:illegal_transition, %{reason: :recoverable_attempt_exists}}} =
             Missions.continue_from_checkpoint(mission.id, Actor.boss(), checkpoint_sha)

    assert Repo.aggregate(Attempt, :count) == 2
  end

  defp running_project_attempt!(source, base_sha) do
    {:ok, project} =
      Projects.register(
        %{name: "exact", repository_path: source, repository_url: "file://#{source}"},
        Actor.boss()
      )

    {:ok, mission} =
      Missions.create(
        Fixtures.mission_attrs(%{project_id: project.id, base_sha: base_sha}),
        Actor.boss()
      )

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Missions.grant_work_authorization(mission.id, Actor.boss())
    workspace_path = Path.join(Home.workspaces_dir(), mission.id)

    {:ok, %{attempt: attempt, workspace: workspace}} =
      Missions.start(mission.id, Actor.system(), %{workspace_path: workspace_path})

    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())

    {:ok, attempt} =
      Attempts.mark_running(attempt.id, Actor.system(), %{fencing_token: attempt.fencing_token})

    %{project: project, mission: mission, attempt: attempt, workspace: workspace}
  end

  defp record_terminal_event!(attempt, sequence) do
    assert {:ok, :accepted} =
             Events.ingest(
               %{
                 "event_id" => "terminal-#{attempt.id}",
                 "type" => "session.completed",
                 "native_sequence" => sequence,
                 "attempt_id" => attempt.id,
                 "payload" => %{}
               },
               Actor.attempt(attempt.id, attempt.fencing_token)
             )
  end

  defp record_checkpoint_event!(attempt, sha, sequence) do
    assert {:ok, :accepted} =
             Events.ingest(
               %{
                 "event_id" => "checkpoint-#{attempt.id}",
                 "type" => "turn.completed",
                 "native_sequence" => sequence,
                 "attempt_id" => attempt.id,
                 "payload" => %{"sha" => sha}
               },
               Actor.attempt(attempt.id, attempt.fencing_token)
             )
  end

  defp mint_capability!(attempt) do
    {:ok, secret} = Consigliere.Capabilities.mint(attempt)
    {:ok, capability} = Consigliere.Capabilities.authenticate(secret)
    {secret, capability}
  end

  defp complete_via_protocol(secret, attempt, mission, workspace, sha, sequence) do
    call_protocol(
      "attempt.complete",
      secret,
      attempt,
      mission,
      workspace,
      sha,
      sequence,
      "completed"
    )
  end

  defp checkpoint_via_protocol(secret, attempt, mission, workspace, sha, sequence) do
    call_protocol(
      "attempt.checkpoint",
      secret,
      attempt,
      mission,
      workspace,
      sha,
      sequence,
      "checkpoint"
    )
  end

  defp call_protocol(op, secret, attempt, mission, workspace, sha, sequence, kind) do
    response =
      Consigliere.API.Protocol.handle(
        JSON.encode!(%{
          "v" => 1,
          "id" => "result-#{System.unique_integer([:positive])}",
          "op" => op,
          "capability" => secret,
          "payload" => %{
            "attempt_id" => attempt.id,
            "mission_id" => mission.id,
            "project_id" => mission.project_id,
            "workspace_id" => workspace.id,
            "workspace_generation" => workspace.lease_id,
            "base_sha" => mission.base_sha,
            "fencing_generation" => attempt.fencing_token,
            "terminal_sequence" => sequence,
            "result_sha" => sha,
            "result_kind" => kind
          }
        }),
        :capability
      )

    {:ok, JSON.decode!(response)}
    |> case do
      {:ok, %{"ok" => true, "payload" => payload}} -> {:ok, payload}
      {:ok, %{"ok" => false, "error" => error}} -> {:error, error}
    end
  end
end
