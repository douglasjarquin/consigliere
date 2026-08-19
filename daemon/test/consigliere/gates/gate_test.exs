defmodule Consigliere.Gates.GateTest do
  use ExUnit.Case, async: true

  alias Consigliere.Repo
  alias Consigliere.Fixtures
  alias Consigliere.Gates.Gate

  defp attrs(mission, overrides \\ %{}) do
    Map.merge(
      %{
        mission_id: mission.id,
        gate_type: "review",
        input_sha: "abc123",
        base_sha: "def456",
        policy_hash: "policy1",
        status: "pending"
      },
      overrides
    )
  end

  test "a valid changeset inserts and round-trips" do
    mission = Fixtures.mission!()

    assert {:ok, gate} = Repo.insert(Gate.changeset(%Gate{}, attrs(mission)))
    assert Repo.get(Gate, gate.id).status == "pending"
  end

  test "an unknown status is rejected" do
    mission = Fixtures.mission!()
    changeset = Gate.changeset(%Gate{}, attrs(mission, %{status: "nonsense"}))
    refute changeset.valid?
  end

  test "a second Gate with the identical (mission, type, input_sha, base_sha, policy_hash) tuple is rejected while the first is not invalidated" do
    mission = Fixtures.mission!()
    assert {:ok, _} = Repo.insert(Gate.changeset(%Gate{}, attrs(mission)))

    assert {:error, changeset} = Repo.insert(Gate.changeset(%Gate{}, attrs(mission)))

    assert "has already been taken" in errors_for(changeset, :mission_id)
  end

  test "a second Gate with the identical tuple IS allowed once the first is invalidated" do
    mission = Fixtures.mission!()
    {:ok, first} = Repo.insert(Gate.changeset(%Gate{}, attrs(mission)))

    {:ok, _} =
      Repo.update(Gate.changeset(first, %{status: "invalidated"}))

    assert {:ok, _second} = Repo.insert(Gate.changeset(%Gate{}, attrs(mission)))
  end

  defp errors_for(changeset, field) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
    |> Map.get(field, [])
  end
end
