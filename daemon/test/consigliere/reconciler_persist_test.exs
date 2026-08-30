defmodule Consigliere.ReconcilerPersistTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Attempts.Attempt
  alias Consigliere.DispatchOperations
  alias Consigliere.Fixtures
  alias Consigliere.GlobalScheduler
  alias Consigliere.Incidents.Incident
  alias Consigliere.Missions
  alias Consigliere.ProcessGroup
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
      Missions.create(Fixtures.mission_attrs(), Actor.boss())

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Fixtures.grant_work_quietly(mission.id, Actor.boss())

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

  defp starting_attempt! do
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())
    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Fixtures.grant_work_quietly(mission.id, Actor.boss())

    {:ok, %{mission: mission, attempt: attempt, workspace: workspace}} =
      Missions.start(mission.id, Actor.system(), %{
        workspace_path: "/tmp/cs-#{System.unique_integer([:positive])}"
      })

    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())
    %{mission: mission, attempt: attempt, workspace: workspace}
  end

  defp write_manifest!(home, attempt_id, attrs) do
    dir = Path.join([home, "runtime", "attempts", attempt_id])
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
    {:ok, _operation} = DispatchOperations.ensure(attempt, %{slot_state: "granted"})
    assert {:ok, :granted} = GlobalScheduler.request_slot(attempt.mission_id)
    write_manifest!(home, attempt.id, %{"state" => "dead_unverified"})

    results = Reconciler.run(home: home)
    assert {:quarantined, _} = Enum.find(results, &match?({:quarantined, _}, &1))
    assert Repo.get!(Attempt, attempt.id).status == "lost"
    assert Repo.get!(Workspace, workspace.id).status == "quarantined"
    assert DispatchOperations.get_by_attempt(attempt.id).slot_state == "unknown"
    assert {:error, :busy} = GlobalScheduler.request_slot("unverified-replacement")
    assert Repo.aggregate(Incident, :count) >= 1
  end

  test "a corrupt manifest records an incident and still reconciles a later Attempt", %{
    home: home
  } do
    %{attempt: attempt} = running_attempt!()
    write_manifest!(home, "not-a-uuid", %{"state" => "nope"})
    File.write!(Path.join([home, "runtime", "attempts", "not-a-uuid", "manifest.json"]), "{nope")
    write_manifest!(home, attempt.id, %{"state" => "dead_verified"})

    results = Reconciler.run(home: home)
    assert Enum.any?(results, &match?({:incident, :corrupt}, &1))
    assert Repo.get!(Attempt, attempt.id).status == "lost"
  end

  test "an already-terminal Attempt with a dead_verified manifest is left untouched", %{
    home: home
  } do
    %{attempt: attempt} = running_attempt!()
    {:ok, _} = Attempts.fail(attempt.id, Actor.system(), %{process_group: :dead_verified})
    write_manifest!(home, attempt.id, %{"state" => "dead_verified"})

    results = Reconciler.run(home: home)
    assert {:skipped, _} = Enum.find(results, &match?({:skipped, _}, &1))
    assert Repo.get!(Attempt, attempt.id).status == "failed"
  end

  test "a live manifest for a terminal Attempt is terminated, not skipped", %{home: home} do
    %{attempt: attempt} = running_attempt!()
    {port, pgid} = Consigliere.ProcessHelpers.spawn_session_leader()

    on_exit(fn ->
      System.cmd("kill", ["-9", "--", "-#{pgid}"], stderr_to_stdout: true)
      if Port.info(port), do: Port.close(port)
    end)

    {:ok, _} = Repo.update(Attempt.changeset(attempt, %{pgid: pgid}))
    {:ok, _} = Attempts.fail(attempt.id, Actor.system(), %{process_group: :dead_verified})

    write_manifest!(
      home,
      attempt.id,
      Map.merge(live_process_attrs(pgid), %{"state" => "running", "pgid" => pgid})
    )

    results = Reconciler.run(home: home)
    assert Enum.any?(results, &match?({:reaped, _}, &1))
    assert Repo.get!(Attempt, attempt.id).status == "failed"
    Consigliere.ProcessHelpers.wait_group_gone(pgid)
  end

  test "accepted session.completed without a SHA is protocol failure, not lost", %{home: home} do
    %{attempt: attempt} = running_attempt!()

    {:ok, _} =
      Repo.update(Attempt.changeset(attempt, %{exit_classification: "completed"}))

    write_manifest!(home, attempt.id, %{"state" => "dead_verified"})
    results = Reconciler.run(home: home)
    assert {:failed, _} = Enum.find(results, &match?({:failed, _}, &1))
    assert Repo.get!(Attempt, attempt.id).status == "failed"
    assert Repo.get!(Attempt, attempt.id).exit_classification == "protocol_failure"
  end

  test "nil Attempt.pgid with a live matching manifest does not claim verified death", %{
    home: home
  } do
    %{attempt: attempt} = running_attempt!()
    {port, pgid} = Consigliere.ProcessHelpers.spawn_session_leader()

    on_exit(fn ->
      System.cmd("kill", ["-9", "--", "-#{pgid}"], stderr_to_stdout: true)
      if Port.info(port), do: Port.close(port)
    end)

    {:ok, _} = Repo.update(Attempt.changeset(attempt, %{pgid: nil}))

    write_manifest!(
      home,
      attempt.id,
      Map.merge(live_process_attrs(pgid), %{"state" => "running", "pgid" => pgid})
    )

    results = Reconciler.run(home: home)
    Consigliere.ProcessHelpers.wait_group_gone(pgid)
    refute Consigliere.ProcessGroup.alive?(pgid)

    assert Enum.any?(results, fn
             {:lost, id} -> id == attempt.id
             {:quarantined, id} -> id == attempt.id
             _ -> false
           end)
  end

  test "a forged manifest pgid of an unrelated live process is never signaled", %{home: home} do
    {port, pgid} = Consigliere.ProcessHelpers.spawn_session_leader()

    on_exit(fn ->
      System.cmd("kill", ["-9", "--", "-#{pgid}"], stderr_to_stdout: true)
      if Port.info(port), do: Port.close(port)
    end)

    write_manifest!(home, Ecto.UUID.generate(), %{
      "state" => "running",
      "pgid" => pgid,
      "mission_id" => Ecto.UUID.generate(),
      "fencing_token" => "forge"
    })

    _results = Reconciler.run(home: home)
    assert Consigliere.ProcessGroup.alive?(pgid)
    if Port.info(port), do: :ok
  end

  test "occupying Attempt with no manifest and no live runner is marked lost unconfirmed" do
    %{attempt: attempt, workspace: workspace} = running_attempt!()

    results =
      Reconciler.run(
        home: Path.join(System.tmp_dir!(), "empty-#{System.unique_integer([:positive])}")
      )

    assert {:quarantined, id} = Enum.find(results, &match?({:quarantined, _}, &1))
    assert id == attempt.id
    assert Repo.get!(Workspace, workspace.id).status == "quarantined"
  end

  test "a live RunnerProcess skips the Attempt", %{home: home} do
    %{attempt: attempt} = starting_attempt!()
    write_manifest!(home, attempt.id, %{"state" => "dead_verified"})

    heartbeat = Path.join(System.tmp_dir!(), "hb-#{System.unique_integer([:positive])}")

    {:ok, runner} =
      DynamicSupervisor.start_child(
        Consigliere.RunnerDynamicSupervisor,
        {Consigliere.RunnerProcess,
         attempt_id: attempt.id,
         mission_id: attempt.mission_id,
         fencing_token: attempt.fencing_token,
         heartbeat_file: heartbeat}
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

  test "checkpoint_requested without a durable result is lost on dead_verified",
       %{home: home} do
    %{attempt: attempt, mission: mission} = running_attempt!()

    {:ok, _} =
      Attempts.request_checkpoint(attempt.id, Actor.system(), %{reported_checkpoint_sha: "abc"})

    {:ok, _} =
      Repo.update(
        Consigliere.Missions.Mission.changeset(
          Repo.get!(Consigliere.Missions.Mission, mission.id),
          %{
            current_checkpoint_sha: "abc"
          }
        )
      )

    write_manifest!(home, attempt.id, %{"state" => "dead_verified"})
    results = Reconciler.run(home: home)
    assert {:lost, _} = Enum.find(results, &match?({:lost, _}, &1))
    assert Repo.get!(Attempt, attempt.id).status == "lost"
  end

  test "a running manifest with no Attempt row does not signal the claimed process group", %{
    home: home
  } do
    {port, pgid} = Consigliere.ProcessHelpers.spawn_session_leader()

    on_exit(fn ->
      System.cmd("kill", ["-9", "--", "-#{pgid}"], stderr_to_stdout: true)
      if Port.info(port), do: Port.close(port)
    end)

    write_manifest!(home, Ecto.UUID.generate(), %{
      "state" => "running",
      "pgid" => pgid
    })

    results = Reconciler.run(home: home)

    assert Enum.any?(results, fn
             {:incident, _} -> true
             {:skipped, _} -> true
             _ -> false
           end)

    assert Consigliere.ProcessGroup.alive?(pgid)
    assert Repo.aggregate(Incident, :count) >= 1
    if Port.info(port), do: :ok
  end

  test "adopt-and-kill of a live group with an Attempt row terminates it and marks the Attempt lost",
       %{home: home} do
    %{attempt: attempt} = running_attempt!()
    {port, pgid} = Consigliere.ProcessHelpers.spawn_session_leader()

    on_exit(fn ->
      System.cmd("kill", ["-9", "--", "-#{pgid}"], stderr_to_stdout: true)
      if Port.info(port), do: Port.close(port)
    end)

    {:ok, _} = Repo.update(Attempt.changeset(attempt, %{pgid: pgid}))

    write_manifest!(
      home,
      attempt.id,
      Map.merge(live_process_attrs(pgid), %{"state" => "running", "pgid" => pgid})
    )

    results = Reconciler.run(home: home)
    assert {:lost, id} = Enum.find(results, &match?({:lost, _}, &1))
    assert id == attempt.id
    assert Repo.get!(Attempt, attempt.id).status == "lost"
    Consigliere.ProcessHelpers.wait_group_gone(pgid)
  end

  test "a missing runner with a verified harness adopts and kills the recorded group",
       %{home: home} do
    %{attempt: attempt} = running_attempt!()
    {runner_port, dead_runner_pid} = Consigliere.ProcessHelpers.spawn_session_leader()
    ProcessGroup.terminate(dead_runner_pid, term_timeout_ms: 100, kill_timeout_ms: 100)
    if Port.info(runner_port), do: Port.close(runner_port)

    {harness_port, harness_pid} = Consigliere.ProcessHelpers.spawn_session_leader()

    on_exit(fn ->
      _ = System.cmd("kill", ["-9", "--", "-#{harness_pid}"], stderr_to_stdout: true)
      if Port.info(harness_port), do: Port.close(harness_port)
    end)

    {:ok, _} = Repo.update(Attempt.changeset(attempt, %{pgid: harness_pid}))

    write_manifest!(
      home,
      attempt.id,
      %{
        "state" => "running",
        "pgid" => harness_pid,
        "runner_pid" => dead_runner_pid,
        "harness_pid" => harness_pid
      }
    )

    results = Reconciler.run(home: home)

    assert {:lost, id} = Enum.find(results, &match?({:lost, _}, &1))
    assert id == attempt.id
    assert Repo.get!(Attempt, attempt.id).status == "lost"
    Consigliere.ProcessHelpers.wait_group_gone(harness_pid)
  end

  test "an Attempt without a manifest never signals an unverified live process group", %{
    home: home
  } do
    %{attempt: attempt, workspace: workspace} = running_attempt!()
    {port, pgid} = Consigliere.ProcessHelpers.spawn_session_leader()

    on_exit(fn ->
      System.cmd("kill", ["-9", "--", "-#{pgid}"], stderr_to_stdout: true)
      if Port.info(port), do: Port.close(port)
    end)

    {:ok, _} = Repo.update(Attempt.changeset(attempt, %{pgid: pgid}))
    results = Reconciler.run(home: home)

    assert {:quarantined, id} = Enum.find(results, &match?({:quarantined, _}, &1))
    assert id == attempt.id
    assert Consigliere.ProcessGroup.liveness(pgid) == :verified
    assert Repo.get!(Workspace, workspace.id).status == "quarantined"
  end

  defp live_process_attrs(pid) do
    {runner_port, runner_pid} = Consigliere.ProcessHelpers.spawn_session_leader()
    executable = session_leader_executable()

    on_exit(fn ->
      _ = ProcessGroup.terminate(runner_pid, term_timeout_ms: 100, kill_timeout_ms: 100)
      if Port.info(runner_port), do: Port.close(runner_port)
    end)

    %{
      "runner_pid" => runner_pid,
      "runner_executable_path" => executable,
      "harness_pid" => pid,
      "harness_executable_path" => executable
    }
  end

  defp session_leader_executable do
    if System.find_executable("setsid") do
      System.find_executable("sleep") || "/bin/sleep"
    else
      System.find_executable("ruby") || System.find_executable("ruby3") || "/usr/bin/ruby"
    end
  end
end
