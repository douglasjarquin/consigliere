defmodule Consigliere.CommandReceiptsTest do
  use ExUnit.Case, async: false

  alias Consigliere.API.Protocol
  alias Consigliere.Actor
  alias Consigliere.CommandReceipts
  alias Consigliere.DatabaseWriter
  alias Consigliere.Fixtures
  alias Consigliere.Repo

  setup do
    Fixtures.reset_phase1_tables!()
    :ok
  end

  defp handle(id, op, payload, actor \\ %{"principal" => "boss"}, idem \\ nil) do
    {:ok, map} =
      JSON.decode(
        Protocol.handle(
          JSON.encode!(%{
            "v" => 1,
            "id" => id,
            "idempotency_key" => idem || id,
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

  test "a canonical hash failure rejects an invalid payload before claiming a receipt" do
    response =
      handle(
        "canonical-invalid",
        "mission.submit",
        %{"mission_id" => nil},
        %{"principal" => "boss"},
        "canonical-invalid-key"
      )

    assert response["error"]["code"] == "invalid"

    {:ok, response} =
      JSON.decode(
        Protocol.handle(
          JSON.encode!(%{
            "v" => 1,
            "id" => "canonical-invalid-hash",
            "op" => "mission.submit",
            "operation_version" => 1,
            "canonical_hash" => "not-a-valid-hash",
            "idempotency_key" => "canonical-invalid-hash-key",
            "actor" => %{"principal" => "boss"},
            "payload" => %{"mission_id" => nil}
          })
        )
      )

    assert response["error"]["reason"] == "canonical_request_invalid"

    assert Repo.get_by(Consigliere.CommandReceipts.CommandReceipt,
             idempotency_key: "canonical-invalid-hash-key"
           ) == nil
  end

  test "a failed command replays as the same failure, not ok true" do
    missing = Ecto.UUID.generate()
    first = handle("k-fail", "mission.submit", %{"mission_id" => missing})
    second = handle("k-fail", "mission.submit", %{"mission_id" => missing})

    assert first["ok"] == false
    assert second["ok"] == false
    assert first["error"]["code"] == second["error"]["code"]
  end

  test "database-only finalization failure rolls back the domain mutation and receipt" do
    project_id = Fixtures.dummy_project!().id

    {:ok, _} =
      Repo.query("""
      CREATE TRIGGER receipt_finalize_crash
      BEFORE UPDATE OF status ON command_receipts
      WHEN NEW.status = 'committed'
      BEGIN
        SELECT RAISE(ABORT, 'receipt finalization crash');
      END
      """)

    on_exit(fn ->
      Repo.query("DROP TRIGGER IF EXISTS receipt_finalize_crash")
    end)

    response =
      handle("atomic-finalize-crash", "mission.create", %{
        "objective" => "o",
        "scope" => "s",
        "acceptance_criteria" => "a",
        "project_id" => project_id
      })

    assert response["ok"] == false
    assert response["error"]["code"] == "transient"
    assert Repo.aggregate(Consigliere.Missions.Mission, :count) == 0

    assert Repo.get_by(Consigliere.CommandReceipts.CommandReceipt,
             idempotency_key: "atomic-finalize-crash"
           ) == nil
  end

  test "an invalid first request stores and replays one bounded failure" do
    first =
      handle(
        "invalid-correlation-1",
        "mission.submit",
        %{},
        %{"principal" => "boss"},
        "invalid-key"
      )

    second =
      handle(
        "invalid-correlation-2",
        "mission.submit",
        %{},
        %{"principal" => "boss"},
        "invalid-key"
      )

    assert first["id"] != second["id"]
    assert first["ok"] == false
    assert first["error"] == second["error"]
    assert first["error"]["code"] == "invalid"
    assert Repo.aggregate(Consigliere.CommandReceipts.CommandReceipt, :count) == 1
  end

  test "same key with distinct invalid payloads is a conflict" do
    first =
      handle(
        "invalid-conflict-1",
        "mission.submit",
        %{"mission_id" => nil},
        %{"principal" => "boss"},
        "invalid-conflict-key"
      )

    second =
      handle(
        "invalid-conflict-2",
        "mission.submit",
        %{"mission_id" => false},
        %{"principal" => "boss"},
        "invalid-conflict-key"
      )

    assert first["ok"] == false
    assert second["ok"] == false
    assert second["error"]["code"] == "idempotency_conflict"
  end

  test "boot reconciliation closes pending receipts once without invoking work" do
    payload = %{"name" => "project", "repository_path" => "/tmp/project"}

    {:ok, request_hash} =
      CommandReceipts.request_hash(Actor.boss(), "project.add", "pending-key", payload)

    {:ok, receipt} =
      Repo.insert(
        Consigliere.CommandReceipts.CommandReceipt.changeset(
          %Consigliere.CommandReceipts.CommandReceipt{},
          %{
            idempotency_key: "pending-key",
            op: "project.add",
            principal: "boss",
            payload_hash: request_hash,
            response: %{},
            status: "pending"
          }
        )
      )

    assert {:ok, 1} = CommandReceipts.reconcile_pending()

    assert Repo.get!(Consigliere.CommandReceipts.CommandReceipt, receipt.id).status ==
             "recovery_required"

    assert {:ok, :replay, envelope} =
             CommandReceipts.remember(Actor.boss(), "project.add", "pending-key", payload, fn ->
               flunk("recovered receipt must not invoke external work")
             end)

    assert envelope["ok"] == false
    assert envelope["error"]["code"] == "operation_recovery_required"
    assert envelope["error"]["operation_id"] == receipt.id
    assert {:ok, 0} = CommandReceipts.reconcile_pending()
  end

  test "external receipt response references its durable operation" do
    assert {:ok, %{"id" => "external-1"}} =
             CommandReceipts.remember(
               Actor.boss(),
               "project.add",
               "external-operation-reference",
               %{"name" => "project", "repository_path" => "/tmp/project"},
               fn -> {:ok, %{"id" => "external-1"}} end
             )

    receipt =
      Repo.get_by!(Consigliere.CommandReceipts.CommandReceipt,
        idempotency_key: "external-operation-reference"
      )

    assert receipt.response["operation_id"] == receipt.id
  end

  test "a supplied canonical request hash must match the authenticated request" do
    project_id = Fixtures.dummy_project!().id

    payload = %{
      "objective" => "o",
      "scope" => "s",
      "acceptance_criteria" => "a",
      "project_id" => project_id
    }

    {:ok, response} =
      JSON.decode(
        Protocol.handle(
          JSON.encode!(%{
            "v" => 1,
            "id" => "hash-check",
            "operation_version" => 1,
            "canonical_hash" => "not-the-request-hash",
            "idempotency_key" => "hash-key",
            "op" => "mission.create",
            "actor" => %{"principal" => "boss"},
            "payload" => payload
          })
        )
      )

    assert response["ok"] == false
    assert response["error"]["reason"] == "canonical_request_mismatch"
    assert Repo.aggregate(Consigliere.Missions.Mission, :count) == 0
  end

  test "two Attempts may reuse the same idempotency key" do
    a = Actor.attempt("att-1", "fence-1")
    b = Actor.attempt("att-2", "fence-2")
    payload = %{"ping" => true}

    assert {:ok, %{"pong" => 1}} =
             CommandReceipts.remember(a, "ping", "shared", payload, fn ->
               {:ok, %{"pong" => 1}}
             end)

    assert {:ok, %{"pong" => 2}} =
             CommandReceipts.remember(b, "ping", "shared", payload, fn ->
               {:ok, %{"pong" => 2}}
             end)
  end

  test "canonical request bytes bind scope, operation version, key, and sorted payload" do
    assert {:ok, canonical} =
             CommandReceipts.canonical_request(
               Actor.attempt("att-1", "fence-1"),
               "mission.create",
               "key-1",
               %{
                 "z" => 2,
                 "a" => 1,
                 "project_id" => "project-1",
                 "objective" => "objective",
                 "scope" => "scope",
                 "acceptance_criteria" => "criteria"
               }
             )

    assert canonical ==
             ~s({"authority_scope":"attempt:att-1:fence-1","idempotency_key":"key-1","operation":{"name":"mission.create","version":1},"payload":{"a":1,"acceptance_criteria":"criteria","objective":"objective","project_id":"project-1","scope":"scope","z":2}})
  end

  test "fresh receipts persist a versioned bounded result envelope" do
    project_id = Fixtures.dummy_project!().id

    response =
      handle(
        "envelope-correlation",
        "mission.create",
        %{
          "objective" => "o",
          "scope" => "s",
          "acceptance_criteria" => "a",
          "project_id" => project_id
        },
        %{"principal" => "boss"},
        "envelope-key"
      )

    assert response["ok"]

    receipt =
      Repo.get_by!(Consigliere.CommandReceipts.CommandReceipt, idempotency_key: "envelope-key")

    assert receipt.response["v"] == 1
    assert receipt.response["ok"] == true
    assert receipt.response["payload"]["id"] == response["payload"]["id"]
  end

  test "a slow external callback does not hold the serialized writer" do
    parent = self()

    task =
      Task.async(fn ->
        CommandReceipts.remember(
          Actor.boss(),
          "project.add",
          "slow-external",
          %{"name" => "project", "repository_path" => "/tmp/project"},
          fn ->
            send(parent, {:callback_process, self()})
            Process.sleep(500)
            {:ok, %{"id" => "external-1"}}
          end
        )
      end)

    assert_receive {:callback_process, callback_pid}, 1_000
    refute callback_pid == Process.whereis(DatabaseWriter)

    started = System.monotonic_time(:millisecond)
    assert {:ok, _mission} = DatabaseWriter.insert_mission(Fixtures.mission_attrs())
    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed < 400
    assert {:ok, _} = Task.await(task, 2_000)
  end
end
