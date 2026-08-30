defmodule Consigliere.PauseTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Capabilities
  alias Consigliere.Fixtures
  alias Consigliere.Missions
  alias Consigliere.Missions.Mission
  alias Consigliere.ProcessGroup
  alias Consigliere.Repo

  setup do
    Fixtures.reset_phase1_tables!()
    Consigliere.GlobalScheduler.reset()
    :ok
  end

  test "pause with no live Soldier settles paused immediately" do
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())
    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Fixtures.grant_work_quietly(mission.id, Actor.boss())

    assert {:ok, %{mission: paused, status: :paused}} =
             Missions.pause(mission.id, Actor.boss(), "afk")

    assert paused.phase == "paused"

    assert {:ok, %{mission: again, status: :paused}} =
             Missions.pause(mission.id, Actor.boss(), "afk")

    assert again.id == paused.id
  end

  test "pause revokes capability immediately and does not report paused while a runner is live" do
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())
    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Missions.grant_work_authorization(mission.id, Actor.boss())

    [{coord, _}] = wait_coord(mission.id)
    snap = await_runner(coord)
    assert is_pid(snap.runner_pid)
    attempt = Repo.get_by!(Attempt, mission_id: mission.id)
    {:ok, secret} = Capabilities.mint(attempt)

    assert {:ok, result} = Missions.pause(mission.id, Actor.boss())
    assert result.status in [:paused, :pausing]
    assert {:error, "revoked capability"} = authenticate_any(secret)

    if result.status == :paused do
      refute Process.alive?(snap.runner_pid)
      assert Repo.get!(Mission, mission.id).phase == "paused"
    end
  end

  test "pause does not signal a persisted pgid without verified inventory" do
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())
    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Missions.grant_work_authorization(mission.id, Actor.boss())

    {:ok, %{attempt: attempt}} =
      Missions.start(mission.id, Actor.system(), %{
        workspace_path: "/tmp/cs-#{System.unique_integer([:positive])}"
      })

    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())

    {:ok, attempt} =
      Attempts.mark_running(attempt.id, Actor.system(), %{fencing_token: attempt.fencing_token})

    {port, pgid} = Consigliere.ProcessHelpers.spawn_session_leader()

    on_exit(fn ->
      _ = ProcessGroup.terminate(pgid, term_timeout_ms: 100, kill_timeout_ms: 100)
      if Port.info(port), do: Port.close(port)
    end)

    {:ok, _} = Repo.update(Attempt.changeset(attempt, %{pgid: pgid}))

    assert {:ok, result} = Missions.pause(mission.id, Actor.boss())
    assert result.status == :pausing
    assert ProcessGroup.alive?(pgid)
  end

  test "resume from settled pause is idempotent and returns an authorized Mission" do
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())
    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Fixtures.grant_work_quietly(mission.id, Actor.boss())
    {:ok, _} = Missions.pause(mission.id, Actor.boss())

    assert {:ok, resumed} = Missions.resume(mission.id, Actor.boss())
    assert resumed.phase == "authorized"
    assert {:ok, again} = Missions.resume(mission.id, Actor.boss())
    assert again.phase == "authorized"
  end

  defp authenticate_any(secret) do
    Capabilities.authenticate(secret)
  end

  defp wait_coord(mission_id, n \\ 50) do
    case Registry.lookup(Consigliere.Registry, {:mission, mission_id}) do
      [{_, _}] = found ->
        found

      _ when n > 0 ->
        Process.sleep(20)
        wait_coord(mission_id, n - 1)

      _ ->
        flunk("coordinator missing")
    end
  end

  defp await_runner(coord, n \\ 100) do
    snap = Consigliere.MissionCoordinator.snapshot(coord)

    cond do
      is_pid(snap.runner_pid) ->
        snap

      n <= 0 ->
        flunk("runner missing")

      true ->
        Process.sleep(50)
        await_runner(coord, n - 1)
    end
  end
end
