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

  test "a running manifest with no Attempt row adopt-and-kills the live process group", %{
    home: home
  } do
    {port, pgid} = spawn_session_leader()

    on_exit(fn ->
      System.cmd("kill", ["-9", "-#{pgid}"], stderr_to_stdout: true)
      if Port.info(port), do: Port.close(port)
    end)

    write_manifest!(home, "orphan-#{System.unique_integer([:positive])}", %{
      "state" => "running",
      "pgid" => pgid
    })

    results = Reconciler.run(home: home)
    assert Enum.any?(results, &match?({:orphan, :adopt_and_kill}, &1))
    refute_process_group_alive(pgid)
    assert Repo.aggregate(Incident, :count) >= 1
  end

  test "adopt-and-kill of a live group with an Attempt row terminates it and marks the Attempt lost",
       %{home: home} do
    %{attempt: attempt} = running_attempt!()
    {port, pgid} = spawn_session_leader()

    on_exit(fn ->
      System.cmd("kill", ["-9", "-#{pgid}"], stderr_to_stdout: true)
      if Port.info(port), do: Port.close(port)
    end)

    {:ok, _} = Repo.update(Attempt.changeset(attempt, %{pgid: pgid}))
    write_manifest!(home, attempt.id, %{"state" => "running", "pgid" => pgid})

    results = Reconciler.run(home: home)
    assert {:lost, id} = Enum.find(results, &match?({:lost, _}, &1))
    assert id == attempt.id
    assert Repo.get!(Attempt, attempt.id).status == "lost"
    refute_process_group_alive(pgid)
  end

  defp spawn_session_leader do
    ruby = System.find_executable("ruby") || flunk("ruby is required to spawn a setsid process group")

    port =
      Port.open({:spawn_executable, ruby}, [
        :binary,
        :exit_status,
        args: ["-e", "Process.setsid; sleep 60"]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    wait_session_leader!(pid)
    {port, pid}
  end

  defp wait_session_leader!(pid) do
    Enum.reduce_while(1..50, :error, fn _, _ ->
      {out, 0} = System.cmd("ps", ["-o", "pgid=", "-p", to_string(pid)], stderr_to_stdout: true)

      case Integer.parse(String.trim(out)) do
        {pgid, _} when pgid == pid -> {:halt, :ok}
        _ ->
          Process.sleep(20)
          {:cont, :error}
      end
    end)
    |> case do
      :ok -> :ok
      :error -> flunk("pid #{pid} never became its own session leader")
    end
  end

  defp refute_process_group_alive(pgid, attempts \\ 40) do
    {out, status} = System.cmd("kill", ["-0", "-#{pgid}"], stderr_to_stdout: true)

    cond do
      status != 0 and String.contains?(out, "No such process") ->
        :ok

      attempts > 0 ->
        Process.sleep(50)
        refute_process_group_alive(pgid, attempts - 1)

      true ->
        flunk("process group #{pgid} is still alive")
    end
  end
end
