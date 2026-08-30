defmodule Consigliere.Runtime.InventoryTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Fixtures
  alias Consigliere.Home
  alias Consigliere.Missions
  alias Consigliere.ProcessGroup
  alias Consigliere.Runtime.Inventory
  alias Consigliere.Runtime.ProcessIdentity

  setup do
    Fixtures.reset_phase1_tables!()
    home = Path.join(System.tmp_dir!(), "cs-inv-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Home.runtime_attempts_dir(home))
    on_exit(fn -> File.rm_rf(home) end)
    %{home: home}
  end

  test "a canonical running manifest with matching Attempt identity is valid live inventory", %{
    home: home
  } do
    {attempt, _mission} = running_attempt!()
    path = write_manifest!(home, attempt, %{"state" => "running", "pgid" => 424_242})
    assert {:valid_live, manifest, ^attempt} = Inventory.verify(path, home)
    assert manifest["attempt_id"] == attempt.id
  end

  test "live inventory rejects a runner and harness outside the recorded process group", %{
    home: home
  } do
    {group_port, pgid} = Consigliere.ProcessHelpers.spawn_session_leader()
    {other_port, other_pid} = Consigliere.ProcessHelpers.spawn_session_leader()
    executable = System.find_executable("sleep") || "/bin/sleep"

    on_exit(fn ->
      _ = ProcessGroup.terminate(pgid, term_timeout_ms: 100, kill_timeout_ms: 100)
      _ = ProcessGroup.terminate(other_pid, term_timeout_ms: 100, kill_timeout_ms: 100)
      if Port.info(group_port), do: Port.close(group_port)
      if Port.info(other_port), do: Port.close(other_port)
    end)

    {attempt, _mission} = running_attempt!()

    path =
      write_manifest!(home, attempt, %{
        "state" => "running",
        "pgid" => pgid,
        "runner_pid" => other_pid,
        "runner_executable_path" => executable,
        "harness_pid" => other_pid,
        "harness_executable_path" => executable
      })

    assert {:valid_live, manifest, ^attempt} = Inventory.verify(path, home)
    assert Inventory.liveness(manifest) == :identity_mismatch
  end

  test "live inventory accepts the runner outside the harness process group", %{home: home} do
    {harness_port, harness_pid} = Consigliere.ProcessHelpers.spawn_session_leader()
    {runner_port, runner_pid} = Consigliere.ProcessHelpers.spawn_session_leader()

    on_exit(fn ->
      _ = ProcessGroup.terminate(harness_pid, term_timeout_ms: 100, kill_timeout_ms: 100)
      _ = ProcessGroup.terminate(runner_pid, term_timeout_ms: 100, kill_timeout_ms: 100)
      if Port.info(harness_port), do: Port.close(harness_port)
      if Port.info(runner_port), do: Port.close(runner_port)
    end)

    {attempt, _mission} = running_attempt!()

    path =
      write_manifest!(home, attempt, %{
        "state" => "running",
        "pgid" => harness_pid,
        "runner_pid" => runner_pid,
        "harness_pid" => harness_pid
      })

    assert {:valid_live, manifest, ^attempt} = Inventory.verify(path, home)
    assert Inventory.liveness(manifest) == :verified
  end

  test "directory name mismatch is identity_mismatch and is not signalable", %{home: home} do
    {attempt, _} = running_attempt!()
    dir = Path.join(Home.runtime_attempts_dir(home), Ecto.UUID.generate())
    File.mkdir_p!(dir)
    path = Path.join(dir, "manifest.json")

    File.write!(
      path,
      JSON.encode!(%{
        "schema_version" => 1,
        "attempt_id" => attempt.id,
        "mission_id" => attempt.mission_id,
        "fencing_token" => attempt.fencing_token,
        "state" => "running",
        "pgid" => 424_242
      })
    )

    assert Inventory.verify(path, home) == :identity_mismatch
    refute Inventory.signalable?(Inventory.verify(path, home))
  end

  test "fencing token mismatch is stale generation and is not signalable", %{home: home} do
    {attempt, _} = running_attempt!()

    path =
      write_manifest!(home, attempt, %{"fencing_token" => "other-fence", "state" => "running"})

    assert Inventory.verify(path, home) == :stale_generation
    refute Inventory.signalable?(:stale_generation)
  end

  test "pgid 1 is unsafe and is not signalable", %{home: home} do
    {attempt, _} = running_attempt!()
    path = write_manifest!(home, attempt, %{"pgid" => 1, "state" => "running"})
    assert Inventory.verify(path, home) == :unsafe_pgid
    refute Inventory.signalable?(:unsafe_pgid)
  end

  test "a forged live pgid with no Attempt row is not signalable", %{home: home} do
    id = Ecto.UUID.generate()
    dir = Path.join(Home.runtime_attempts_dir(home), id)
    File.mkdir_p!(dir)
    path = Path.join(dir, "manifest.json")

    File.write!(
      path,
      JSON.encode!(%{
        "schema_version" => 1,
        "attempt_id" => id,
        "mission_id" => Ecto.UUID.generate(),
        "fencing_token" => "forge",
        "state" => "running",
        "pgid" => 424_242
      })
    )

    assert Inventory.verify(path, home) == :identity_mismatch
    refute Inventory.signalable?(:identity_mismatch)
  end

  test "liveness categories fail closed for unsafe and absent process groups" do
    assert Inventory.liveness(%{"pgid" => 0}) == :identity_mismatch
    assert Inventory.liveness(%{"pgid" => 1}) == :identity_mismatch
    assert ProcessGroup.liveness(0) == :identity_mismatch

    dead_pgid = find_dead_pgid()
    assert Inventory.liveness(%{"pgid" => dead_pgid}) == :absent

    {port, live_pgid} = Consigliere.ProcessHelpers.spawn_session_leader()

    on_exit(fn ->
      System.cmd("kill", ["-9", "--", "-#{live_pgid}"], stderr_to_stdout: true)
      if Port.info(port), do: Port.close(port)
    end)

    assert Inventory.liveness(%{"pgid" => live_pgid}) == :identity_mismatch

    assert ProcessIdentity.verify(System.pid(), "/definitely/not-the-daemon") ==
             :identity_mismatch

    assert Inventory.liveness(%{
             "pgid" => dead_pgid,
             "runner_pid" => String.to_integer(System.pid()),
             "runner_executable_path" => "/definitely/not-the-daemon"
           }) == :identity_mismatch
  end

  test "liveness identifies a missing runner with a verified harness as orphaned_runner" do
    {runner_port, dead_runner_pid} = Consigliere.ProcessHelpers.spawn_session_leader()
    ProcessGroup.terminate(dead_runner_pid, term_timeout_ms: 100, kill_timeout_ms: 100)
    if Port.info(runner_port), do: Port.close(runner_port)

    {harness_port, harness_pid} = Consigliere.ProcessHelpers.spawn_session_leader()

    on_exit(fn ->
      _ = ProcessGroup.terminate(harness_pid, term_timeout_ms: 100, kill_timeout_ms: 100)
      if Port.info(harness_port), do: Port.close(harness_port)
    end)

    manifest = %{
      "pgid" => harness_pid,
      "runner_pid" => dead_runner_pid,
      "harness_pid" => harness_pid
    }

    assert Inventory.liveness(manifest) == :orphaned_runner
  end

  defp running_attempt! do
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())
    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Fixtures.grant_work_quietly(mission.id, Actor.boss())

    {:ok, %{attempt: attempt, mission: mission}} =
      Missions.start(mission.id, Actor.system(), %{
        workspace_path: "/tmp/cs-#{System.unique_integer([:positive])}"
      })

    {:ok, attempt} = Consigliere.Attempts.request_spawn(attempt.id, Actor.system())

    {:ok, attempt} =
      Consigliere.Attempts.mark_running(attempt.id, Actor.system(), %{
        fencing_token: attempt.fencing_token,
        pgid: 424_242
      })

    {attempt, mission}
  end

  defp write_manifest!(home, attempt, attrs) do
    dir = Path.join(Home.runtime_attempts_dir(home), attempt.id)
    File.mkdir_p!(dir)

    manifest =
      Map.merge(
        %{
          "schema_version" => 1,
          "attempt_id" => attempt.id,
          "mission_id" => attempt.mission_id,
          "fencing_token" => attempt.fencing_token,
          "state" => "running",
          "pgid" => attempt.pgid || 424_242
        },
        attrs
      )

    path = Path.join(dir, "manifest.json")
    File.write!(path, JSON.encode!(manifest))
    path
  end

  defp find_dead_pgid do
    {port, pgid} = Consigliere.ProcessHelpers.spawn_session_leader()
    System.cmd("kill", ["-9", "--", "-#{pgid}"], stderr_to_stdout: true)
    Consigliere.ProcessHelpers.wait_group_gone(pgid)
    if Port.info(port), do: Port.close(port)
    pgid
  end
end
