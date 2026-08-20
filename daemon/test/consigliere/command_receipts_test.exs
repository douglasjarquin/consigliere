defmodule Consigliere.CommandReceiptsTest do
  use ExUnit.Case, async: false

  alias Consigliere.API.Protocol
  alias Consigliere.Fixtures

  setup do
    Fixtures.reset_phase1_tables!()
    :ok
  end

  defp handle(id, op, payload, actor \\ %{"principal" => "boss"}) do
    {:ok, map} =
      JSON.decode(
        Protocol.handle(
          JSON.encode!(%{
            "v" => 1,
            "id" => id,
            "idempotency_key" => id,
            "op" => op,
            "actor" => actor,
            "payload" => payload
          })
        )
      )

    map
  end

  test "the same mutating request is not applied twice" do
    payload = %{
      "objective" => "o",
      "scope" => "s",
      "acceptance_criteria" => "a",
      "project_id" => Fixtures.dummy_project!().id
    }

    first = handle("k1", "mission.create", payload)
    second = handle("k1", "mission.create", payload)

    assert first["ok"]
    assert second["ok"]
    assert first["payload"]["id"] == second["payload"]["id"]
    assert Consigliere.Repo.aggregate(Consigliere.Missions.Mission, :count) == 1
  end

  test "the same key with a different payload is a conflict" do
    project_id = Fixtures.dummy_project!().id

    assert handle("k2", "mission.create", %{
             "objective" => "o",
             "scope" => "s",
             "acceptance_criteria" => "a",
             "project_id" => project_id
           })["ok"]

    conflict =
      handle("k2", "mission.create", %{
        "objective" => "other",
        "scope" => "s",
        "acceptance_criteria" => "a",
        "project_id" => project_id
      })

    assert conflict["ok"] == false
    assert conflict["error"]["reason"] =~ "idempotency_conflict"
  end
end
