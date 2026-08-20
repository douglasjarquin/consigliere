defmodule Consigliere.Runtime.InventoryTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Fixtures
  alias Consigliere.Home
  alias Consigliere.Missions
  alias Consigliere.Runtime.Inventory

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
end
