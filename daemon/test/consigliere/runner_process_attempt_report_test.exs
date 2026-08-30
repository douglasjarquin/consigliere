defmodule Consigliere.RunnerProcessAttemptReportTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Fixtures
  alias Consigliere.Git
  alias Consigliere.Harness.Codex
  alias Consigliere.Repo
  alias Consigliere.RunnerProcess

  setup do
    Fixtures.reset_phase1_tables!()
    Consigliere.GlobalScheduler.reset()
    previous = Application.get_env(:consigliere_daemon, :harness_adapter)
    Application.put_env(:consigliere_daemon, :harness_adapter, Codex)

    on_exit(fn -> Application.put_env(:consigliere_daemon, :harness_adapter, previous) end)
    :ok
  end

  test "routes a private completion marker through the authenticated runner bridge" do
    root = Path.join(System.tmp_dir!(), "cs-attempt-report-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    Git.init_workspace(source)
    File.write!(Path.join(source, "README"), "base\n")
    base_sha = Git.commit_all(source, "base")

    {:ok, project} =
      Consigliere.Projects.register(
        %{name: "report", repository_path: source, repository_url: "file://#{source}"},
        Actor.boss()
      )

    {:ok, mission} =
      Consigliere.Missions.create(
        Fixtures.mission_attrs(%{project_id: project.id, base_sha: base_sha}),
        Actor.boss()
      )

    {:ok, mission} = Consigliere.Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Consigliere.Missions.grant_work_authorization(mission.id, Actor.boss())

    {:ok, %{attempt: attempt, workspace: workspace}} =
      Consigliere.Missions.start(
        mission.id,
        Actor.system(),
        %{workspace_path: Path.join(Consigliere.Home.workspaces_dir(), mission.id)}
      )

    File.write!(Path.join(workspace.path, "result.txt"), "result\n")
    result_sha = Git.commit_all(workspace.path, "result")
    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())

    {:ok, attempt} =
      Attempts.mark_running(attempt.id, Actor.system(), %{fencing_token: attempt.fencing_token})

    {:ok, capability} = Consigliere.Capabilities.mint(attempt)
    {:ok, capability_record} = Consigliere.Capabilities.authenticate(capability)

    marker =
      "CS_ATTEMPT_REPORT_V1:" <>
        (JSON.encode!(%{
           "operation" => "complete",
           "payload" => %{"result_sha" => result_sha}
         })
         |> Base.encode16(case: :lower))

    script = Path.join(root, "codex-marker")

    File.write!(
      script,
      "#!/bin/sh\n" <>
        "printf '%s\\n' '" <>
        JSON.encode!(%{"type" => "thread.started", "thread_id" => "session-bridge"}) <>
        "'\n" <>
        "printf '%s\\n' '" <>
        JSON.encode!(%{
          "type" => "item.completed",
          "item" => %{"type" => "command_execution", "aggregated_output" => marker <> "\n"}
        }) <>
        "'\n" <>
        "printf '%s\\n' '" <>
        JSON.encode!(%{
          "type" => "turn.completed",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
        }) <>
        "'\n"
    )

    File.chmod!(script, 0o700)

    {:ok, runner} =
      RunnerProcess.start_link(
        attempt_id: attempt.id,
        mission_id: mission.id,
        project_id: project.id,
        workspace_id: workspace.id,
        workspace_path: workspace.path,
        workspace_generation: workspace.lease_id,
        base_sha: base_sha,
        parent_checkpoint_sha: workspace.parent_checkpoint_sha,
        fencing_token: attempt.fencing_token,
        capability: capability,
        capability_id: capability_record.id,
        capability_generation: capability_record.generation,
        invocation_id: "bridge-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}",
        harness_command: [script]
      )

    wait_until(fn ->
      Repo.get!(Attempt, attempt.id).status == "completed" and
        Repo.get!(Consigliere.Missions.Mission, mission.id).phase == "ready_for_review"
    end)

    assert Repo.get!(Attempt, attempt.id).imported_sha == result_sha
    assert Repo.get!(Consigliere.Missions.Mission, mission.id).phase == "ready_for_review"
    refute Process.alive?(runner)
  end

  defp wait_until(fun, remaining \\ 120) do
    if fun.() do
      :ok
    else
      if remaining <= 0 do
        flunk("condition did not become true")
      else
        Process.sleep(50)
        wait_until(fun, remaining - 1)
      end
    end
  end
end
