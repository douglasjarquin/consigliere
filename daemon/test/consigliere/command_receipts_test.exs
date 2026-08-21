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

  test "the same key used for a different operation is a conflict" do
    project_id = Fixtures.dummy_project!().id

    created =
      handle("k-op", "mission.create", %{
        "objective" => "o",
        "scope" => "s",
        "acceptance_criteria" => "a",
        "project_id" => project_id
      })

    assert created["ok"]
    id = created["payload"]["id"]

    conflict = handle("k-op", "mission.submit", %{"mission_id" => id})
    assert conflict["ok"] == false
    assert conflict["error"]["reason"] =~ "idempotency_conflict"
  end

  test "a failed command replays as the same failure, not ok true" do
    missing = Ecto.UUID.generate()
    first = handle("k-fail", "mission.submit", %{"mission_id" => missing})
    second = handle("k-fail", "mission.submit", %{"mission_id" => missing})

    assert first["ok"] == false
    assert second["ok"] == false
    assert first["error"]["code"] == second["error"]["code"]
  end

  test "two Attempts may reuse the same idempotency key" do
    a = Consigliere.Actor.attempt("att-1", "fence-1")
    b = Consigliere.Actor.attempt("att-2", "fence-2")
    payload = %{"ping" => true}

    assert {:ok, %{"pong" => 1}} =
             Consigliere.CommandReceipts.remember(a, "ping", "shared", payload, fn ->
               {:ok, %{"pong" => 1}}
             end)

    assert {:ok, %{"pong" => 2}} =
             Consigliere.CommandReceipts.remember(b, "ping", "shared", payload, fn ->
               {:ok, %{"pong" => 2}}
             end)
  end
end
