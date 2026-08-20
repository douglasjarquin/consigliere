defmodule Consigliere.Made.ProcessTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Fixtures
  alias Consigliere.Gates
  alias Consigliere.Gates.Gate
  alias Consigliere.Made.Process
  alias Consigliere.Made.Validate
  alias Consigliere.Missions
  alias Consigliere.Repo

  setup do
    Fixtures.reset_phase1_tables!()
    previous = System.get_env("CS_MADE_BIN")
    System.put_env("CS_MADE_BIN", Process.fixture_binary())

    on_exit(fn ->
      if previous,
        do: System.put_env("CS_MADE_BIN", previous),
        else: System.delete_env("CS_MADE_BIN")
    end)

    :ok
  end

  defp running_gate! do
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

    {:ok, gate} =
      Gates.create(mission.id, Actor.system(), %{
        gate_type: "review",
        input_sha: "sha-a",
        base_sha: "base",
        policy_hash: "p1"
      })

    {:ok, gate} = Gates.start(gate.id, Actor.system(), %{managed_run_id: "run-a"})
    {attempt, gate}
  end

  test "the fixture binary maps every terminal outcome" do
    assert Process.fixture_binary() =~ "fake_made.sh"

    {attempt, gate} = running_gate!()

    for {forced, expected} <- [
          {:passed, :passed},
          {:needs_decision, :needs_decision},
          {:failed_retryable, :failed_retryable},
          {:failed_terminal, :failed_terminal},
          {:infrastructure_error, :infrastructure_error},
          {:canceled, :canceled}
        ] do
      {:ok, fresh} =
        Gates.create(attempt.mission_id, Actor.system(), %{
          gate_type: "review",
          input_sha: "sha-#{forced}",
          base_sha: "base",
          policy_hash: "p1"
        })

      {:ok, fresh} = Gates.start(fresh.id, Actor.system(), %{managed_run_id: "run-#{forced}"})

      result = Validate.run(fresh, attempt, adapter: Process, forced_outcome: forced)
      assert result.outcome == expected
      assert result.live_pid == nil
      assert Repo.get!(Gate, fresh.id).status != "running"
    end

    _ = gate
  end

  test "production default is Process not Fake" do
    config = File.read!(Path.expand("../../../config/config.exs", __DIR__))
    assert config =~ "Consigliere.Made.Process"
    refute config =~ "made_adapter: Consigliere.Made.Fake"
  end
end
