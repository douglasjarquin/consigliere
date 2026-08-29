defmodule Consigliere.MissionGrantDispatchTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Fixtures
  alias Consigliere.GlobalScheduler
  alias Consigliere.Harness.ContextPack
  alias Consigliere.MissionCoordinator
  alias Consigliere.MissionDynamicSupervisor
  alias Consigliere.Missions
  alias Consigliere.Repo

  setup do
    Fixtures.reset_phase1_tables!()
    GlobalScheduler.reset()
    :ok
  end

  test "grant_work_authorization starts exactly one coordinator and one Attempt without a reboot" do
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())
    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Missions.grant_work_authorization(mission.id, Actor.boss())

    coord = await_coordinator(mission.id)
    snap = await_runner(coord)
    assert is_pid(snap.runner_pid)

    attempts = Repo.all(from_attempts(mission.id))
    assert length(attempts) == 1
    attempt = hd(attempts)
    assert attempt.status in ~w(starting running)
    assert is_binary(attempt.input_context_hash)
    assert byte_size(attempt.input_context_hash) == 64
    assert is_binary(attempt.invocation_id)
    assert attempt.model == "gpt-5"
    assert attempt.reasoning_effort == "high"
    assert attempt.sandbox == "workspace-write"
    assert attempt.approval == "never"
    assert attempt.cli_version == "fake-adapter"
    assert is_integer(attempt.context_bytes)
    assert attempt.context_input_tokens <= 8_192

    context_path =
      Path.join(Consigliere.Home.runtime_attempts_dir(), "#{attempt.id}/context_pack.json")

    assert {:ok, context_stat} = File.stat(context_path)
    assert context_stat.mode == 0o100600
    assert ContextPack.hash(File.read!(context_path)) == attempt.input_context_hash

    assert {:ok, _} = MissionDynamicSupervisor.start_mission(mission_id: mission.id)
    assert length(Repo.all(from_attempts(mission.id))) == 1
    assert length(Registry.lookup(Consigliere.Registry, {:mission, mission.id})) == 1
  end

  test "a planned Attempt with a held slot is recovered into a runner" do
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())
    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Fixtures.grant_work_quietly(mission.id, Actor.boss())

    {:ok, %{attempt: attempt}} =
      Missions.start(mission.id, Actor.system(), %{
        workspace_path: Path.join(System.tmp_dir!(), "cs-#{System.unique_integer([:positive])}")
      })

    assert attempt.status == "planned"
    assert {:ok, _} = GlobalScheduler.request_slot(mission.id)
    assert {:ok, _} = MissionDynamicSupervisor.start_mission(mission_id: mission.id)

    coord = await_coordinator(mission.id)
    snap = await_runner(coord)
    assert is_pid(snap.runner_pid)
    reloaded = Repo.get!(Attempt, attempt.id)
    assert reloaded.status in ~w(starting running)
    assert length(Repo.all(from_attempts(mission.id))) == 1
  end

  test "duplicate start_mission calls return the existing subtree" do
    mission_id = Ecto.UUID.generate()
    assert {:ok, first} = MissionDynamicSupervisor.start_mission(mission_id: mission_id)
    assert {:ok, second} = MissionDynamicSupervisor.start_mission(mission_id: mission_id)
    assert first == second
    assert length(Registry.lookup(Consigliere.Registry, {:mission, mission_id})) == 1
  end

  defp from_attempts(mission_id) do
    import Ecto.Query
    from(a in Attempt, where: a.mission_id == ^mission_id)
  end

  defp await_coordinator(mission_id, remaining \\ 100) do
    case Registry.lookup(Consigliere.Registry, {:mission, mission_id}) do
      [{pid, _}] ->
        pid

      _ when remaining <= 0 ->
        flunk("coordinator never started for #{mission_id}")

      _ ->
        Process.sleep(50)
        await_coordinator(mission_id, remaining - 1)
    end
  end

  defp await_runner(coord, remaining \\ 100) do
    snap = MissionCoordinator.snapshot(coord)

    cond do
      is_pid(snap.runner_pid) ->
        snap

      remaining <= 0 ->
        flunk("runner never started: #{inspect(snap)}")

      true ->
        Process.sleep(50)
        await_runner(coord, remaining - 1)
    end
  end
end
