defmodule Consigliere.Workspaces.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Consigliere.Repo
  alias Consigliere.Fixtures
  alias Consigliere.Workspaces.Workspace

  test "a valid changeset inserts and round-trips" do
    mission = Fixtures.mission!()

    attrs = %{
      mission_id: mission.id,
      path: "/tmp/w",
      lease_id: "lease-1",
      fencing_token: "fence-1",
      status: "active"
    }

    assert {:ok, workspace} = Repo.insert(Workspace.changeset(%Workspace{}, attrs))
    assert Repo.get(Workspace, workspace.id).status == "active"
  end

  test "an unknown status is rejected" do
    mission = Fixtures.mission!()

    attrs = %{
      mission_id: mission.id,
      path: "/tmp/w",
      lease_id: "lease-1",
      fencing_token: "fence-1",
      status: "not_a_real_status"
    }

    refute Workspace.changeset(%Workspace{}, attrs).valid?
  end
end
