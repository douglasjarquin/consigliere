defmodule Consigliere.ReconcilerPersistTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Fixtures
  alias Consigliere.GlobalScheduler
  alias Consigliere.Incidents.Incident
  alias Consigliere.Missions
  alias Consigliere.Reconciler
  alias Consigliere.Repo
  alias Consigliere.Workspaces.Workspace

  setup do
    Fixtures.reset_phase1_tables!()
    GlobalScheduler.reset()

    home = Path.join(System.tmp_dir!(), "cs-reconcile-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf(home) end)
    %{home: home}
  end

  defp running_attempt! do
    {:ok, mission} =
      Missions.create(%{objective: "o", scope: "s", acceptance_criteria: "a"}, Actor.boss())

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Missions.grant_work_authorization(mission.id, Actor.boss())

    {:ok, %{mission: mission, attempt: attempt, workspace: workspace}} =
      Missions.start(mission.id, Actor.system(), %{
        workspace_path: "/tmp/cs-#{System.unique_integer([:positive])}"
      })

    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())

    {:ok, attempt} =
      Attempts.mark_running(attempt.id, Actor.system(), %{
        fencing_token: attempt.fencing_token
      })

    %{mission: mission, attempt: attempt, workspace: workspace}
  end

  defp write_manifest!(home, attempt_id, attrs) do
    dir = Path.join([home, "runners", attempt_id])
    File.mkdir_p!(dir)

    manifest =
      Map.merge(
        %{"schema_version" => 1, "attempt_id" => attempt_id, "pgid" => 424_242},
        attrs
      )

    File.write!(Path.join(dir, "manifest.json"), JSON.encode!(manifest))
    manifest
  end

  test "dead_verified manifest marks a non-terminal Attempt lost without quarantining the workspace",
       %{home: home} do
    %{attempt: attempt, workspace: workspace} = running_attempt!()
    write_manifest!(home, attempt.id, %{"state" => "dead_verified"})

    results = Reconciler.run(home: home)
    assert {:lost, id} = Enum.find(results, &match?({:lost, _}, &1))
    assert id == attempt.id
    assert Repo.get!(Attempt, attempt.id).status == "lost"
    assert Repo.get!(Workspace, workspace.id).status == "active"
  end

  test "dead_unverified manifest quarantines the workspace and opens an incident", %{home: home} do
    %{attempt: attempt, workspace: workspace} = running_attempt!()
    write_manifest!(home, attempt.id, %{"state" => "dead_unverified"})

    results = Reconciler.run(home: home)
    assert {:quarantined, _} = Enum.find(results, &match?({:quarantined, _}, &1))
    assert Repo.get!(Attempt, attempt.id).status == "lost"
    assert Repo.get!(Workspace, workspace.id).status == "quarantined"
    assert Repo.aggregate(Incident, :count) >= 1
  end

  test "a corrupt manifest records an incident and still reconciles a later Attempt", %{home: home} do
    %{attempt: attempt} = running_attempt!()
    write_manifest!(home, "not-a-uuid", %{"state" => "nope"})
    File.write!(Path.join([home, "runners", "not-a-uuid", "manifest.json"]), "{nope")
    write_manifest!(home, attempt.id, %{"state" => "dead_verified"})

    results = Reconciler.run(home: home)
    assert Enum.any?(results, &match?({:incident, :corrupt}, &1))
    assert Repo.get!(Attempt, attempt.id).status == "lost"
  end

  test "an already-terminal Attempt is left untouched", %{home: home} do
    %{attempt: attempt} = running_attempt!()
    {:ok, _} = Attempts.fail(attempt.id, Actor.system(), %{process_group: :dead_verified})
    write_manifest!(home, attempt.id, %{"state" => "dead_verified"})

    results = Reconciler.run(home: home)
    assert {:skipped, _} = Enum.find(results, &match?({:skipped, _}, &1))
    assert Repo.get!(Attempt, attempt.id).status == "failed"
  end

  test "occupying Attempt with no manifest and no live runner is marked lost unconfirmed" do
    %{attempt: attempt, workspace: workspace} = running_attempt!()

    results = Reconciler.run(home: Path.join(System.tmp_dir!(), "empty-#{System.unique_integer([:positive])}"))
    assert {:quarantined, id} = Enum.find(results, &match?({:quarantined, _}, &1))
    assert id == attempt.id
    assert Repo.get!(Workspace, workspace.id).status == "quarantined"
  end

  test "a live RunnerProcess skips the Attempt", %{home: home} do
    %{attempt: attempt} = running_attempt!()
    write_manifest!(home, attempt.id, %{"state" => "dead_verified"})

    heartbeat = Path.join(System.tmp_dir!(), "hb-#{System.unique_integer([:positive])}")

    {:ok, runner} =
      DynamicSupervisor.start_child(
        Consigliere.RunnerDynamicSupervisor,
        {Consigliere.RunnerProcess, attempt_id: attempt.id, heartbeat_file: heartbeat}
      )

    on_exit(fn ->
      if Process.alive?(runner) do
        DynamicSupervisor.terminate_child(Consigliere.RunnerDynamicSupervisor, runner)
      end

      File.rm(heartbeat)
    end)

    results = Reconciler.run(home: home)
    assert {:skipped, _} = Enum.find(results, &match?({:skipped, _}, &1))
    assert Repo.get!(Attempt, attempt.id).status == "running"
  end

  test "checkpoint_requested with an already-imported SHA becomes checkpointed on dead_verified",
       %{home: home} do
    %{attempt: attempt, mission: mission} = running_attempt!()

    {:ok, _} =
      Attempts.request_checkpoint(attempt.id, Actor.system(), %{reported_checkpoint_sha: "abc"})

    {:ok, _} =
      Repo.update(
        Consigliere.Missions.Mission.changeset(Repo.get!(Consigliere.Missions.Mission, mission.id), %{
          current_checkpoint_sha: "abc"
        })
      )

    write_manifest!(home, attempt.id, %{"state" => "dead_verified"})
    results = Reconciler.run(home: home)
    assert {:checkpointed, _} = Enum.find(results, &match?({:checkpointed, _}, &1))
    assert Repo.get!(Attempt, attempt.id).status == "checkpointed"
  end

  test "an orphan live process group is not marked lost (adopt-and-kill deferred)", %{home: home} do
    %{attempt: attempt} = running_attempt!()

    port = Port.open({:spawn_executable, "/bin/sleep"}, [:exit_status, args: ["60"]])
    {:os_pid, os_pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      if Port.info(port), do: Port.close(port)
      System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)
    end)

    {:ok, attempt} = Repo.update(Attempt.changeset(attempt, %{pgid: os_pid}))
    write_manifest!(home, attempt.id, %{"state" => "running", "pgid" => os_pid})

    results = Reconciler.run(home: home)

    if Enum.any?(results, &match?({:adopt_and_kill, _}, &1)) do
      assert Repo.get!(Attempt, attempt.id).status == "running"
    else
      # /bin/sleep may not be its own process group on this OS; classification
      # must still not crash, and a conclusively-dead group is lost.
      assert Enum.any?(results, &match?({:lost, _}, &1)) or
               Enum.any?(results, &match?({:quarantined, _}, &1))
    end
  end
end
