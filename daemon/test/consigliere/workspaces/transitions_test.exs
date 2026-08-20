defmodule Consigliere.Workspaces.TransitionsTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Fixtures
  alias Consigliere.Missions
  alias Consigliere.Workspaces

  setup do
    Fixtures.reset_phase1_tables!()
    :ok
  end

  defp mission! do
    {:ok, mission} =
      Missions.create(Fixtures.mission_attrs(), Actor.system())

    mission
  end

  test "create then daemon_exclusive then release" do
    mission = mission!()

    {:ok, workspace} =
      Workspaces.create(mission.id, Actor.system(), %{
        path: "/tmp/cs-#{System.unique_integer([:positive])}"
      })

    assert workspace.status == "active"

    assert {:error, {:illegal_transition, %{reason: :death_not_verified}}} =
             Workspaces.mark_daemon_exclusive(workspace.id, Actor.system(), %{})

    {:ok, workspace} =
      Workspaces.mark_daemon_exclusive(workspace.id, Actor.system(), %{
        process_group: :dead_verified
      })

    {:ok, workspace} = Workspaces.release(workspace.id, Actor.system())
    assert workspace.status == "released"
  end

  test "quarantine opens an incident; release afterwards is illegal" do
    mission = mission!()

    {:ok, workspace} =
      Workspaces.create(mission.id, Actor.system(), %{
        path: "/tmp/cs-#{System.unique_integer([:positive])}"
      })

    {:ok, workspace} = Workspaces.quarantine(workspace.id, Actor.system(), "unverified")
    assert workspace.status == "quarantined"

    assert {:error, {:illegal_transition, %{reason: :not_daemon_exclusive}}} =
             Workspaces.release(workspace.id, Actor.system())
  end
end
