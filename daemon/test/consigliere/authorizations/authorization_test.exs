defmodule Consigliere.Authorizations.AuthorizationTest do
  use ExUnit.Case, async: true

  import Consigliere.ChangesetHelpers

  alias Consigliere.Repo
  alias Consigliere.Fixtures
  alias Consigliere.Authorizations.Authorization

  test "a valid changeset inserts and round-trips" do
    mission = Fixtures.mission!()

    attrs = %{
      mission_id: mission.id,
      scope: "work",
      granted_by_principal: "boss",
      granted_at: DateTime.utc_now()
    }

    assert {:ok, authorization} = Repo.insert(Authorization.changeset(%Authorization{}, attrs))
    assert Repo.get(Authorization, authorization.id).scope == "work"
  end

  test "consumed_at and expires_at round-trip" do
    mission = Fixtures.mission!()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      mission_id: mission.id,
      scope: "work",
      granted_by_principal: "boss",
      granted_at: now,
      consumed_at: now,
      expires_at: now
    }

    assert {:ok, authorization} = Repo.insert(Authorization.changeset(%Authorization{}, attrs))
    reloaded = Repo.get(Authorization, authorization.id)
    assert reloaded.consumed_at == now
    assert reloaded.expires_at == now
  end

  test "an unknown scope is rejected" do
    mission = Fixtures.mission!()

    attrs = %{
      mission_id: mission.id,
      scope: "not_a_real_scope",
      granted_by_principal: "boss",
      granted_at: DateTime.utc_now()
    }

    refute Authorization.changeset(%Authorization{}, attrs).valid?
  end

  test "missing granted_by_principal is rejected" do
    mission = Fixtures.mission!()
    attrs = %{mission_id: mission.id, scope: "work", granted_at: DateTime.utc_now()}

    refute Authorization.changeset(%Authorization{}, attrs).valid?
  end

  test "a nonexistent mission_id is rejected by the foreign key constraint" do
    attrs = %{
      mission_id: Ecto.UUID.generate(),
      scope: "work",
      granted_by_principal: "boss",
      granted_at: DateTime.utc_now()
    }

    assert {:error, changeset} = Repo.insert(Authorization.changeset(%Authorization{}, attrs))
    assert %{mission_id: ["does not exist"]} = errors_on(changeset)
  end
end
