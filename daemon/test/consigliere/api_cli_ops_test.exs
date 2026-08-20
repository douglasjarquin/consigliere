defmodule Consigliere.API.CLIOpsTest do
  use ExUnit.Case, async: false

  alias Consigliere.API.Protocol
  alias Consigliere.Actor
  alias Consigliere.Fixtures
  alias Consigliere.Home
  alias Consigliere.Missions
  alias Consigliere.Repo

  setup do
    Fixtures.reset_phase1_tables!()
    Consigliere.GlobalScheduler.reset()
    :ok
  end

  defp decode(line) do
    {:ok, map} = JSON.decode(line)
    map
  end

  defp call(op, payload \\ %{}, actor \\ %{"principal" => "boss"}, bound \\ :unbound) do
    decode(
      Protocol.handle(
        JSON.encode!(%{
          "v" => 1,
          "id" => "t-#{System.unique_integer([:positive])}",
          "op" => op,
          "actor" => actor,
          "payload" => payload
        }),
        bound
      )
    )
  end

  test "health reports protocol, release, schema, and adapters" do
    resp = call("health")
    assert resp["ok"] == true
    assert resp["payload"]["protocol"] == 1
    assert resp["payload"]["status"] == "ok"
    assert is_binary(resp["payload"]["release"])
    assert is_integer(resp["payload"]["schema"])
    assert resp["payload"]["harness"] =~ "Consigliere.Harness"
    assert resp["payload"]["runner"]["present"] in [true, false]
  end

  test "version reports the protocol version" do
    resp = call("version")
    assert resp["ok"] == true
    assert resp["payload"]["protocol"] == 1
    assert is_binary(resp["payload"]["release"])
  end

  test "mission.list and mission.why render phase plus open blockers" do
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())
    {:ok, _} = Missions.submit_for_authorization(mission.id, Actor.boss())

    listed = call("mission.list")
    assert listed["ok"] == true
    assert Enum.any?(listed["payload"]["missions"], &(&1["id"] == mission.id))

    why = call("mission.why", %{"mission_id" => mission.id})
    assert why["ok"] == true
    assert why["payload"]["phase"] == "awaiting_authorization"
    assert why["payload"]["runnable"] == false
    assert why["payload"]["reason"] == "phase"
    assert why["payload"]["phase_reason"] == "no work authorization yet"
    assert is_list(why["payload"]["blockers"])
  end

  test "pause opens a blocker and resume closes it; attempts cannot pause" do
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())
    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Fixtures.grant_work_quietly(mission.id, Actor.boss())

    denied =
      call("mission.pause", %{"mission_id" => mission.id}, %{
        "principal" => "attempt",
        "attempt_id" => "a",
        "fencing_token" => "f"
      })

    assert denied["error"]["code"] == "unauthorized"

    paused = call("mission.pause", %{"mission_id" => mission.id})
    assert paused["ok"] == true
    assert paused["payload"]["phase"] in ["authorized", "active"]

    why = call("mission.why", %{"mission_id" => mission.id})
    assert why["payload"]["runnable"] == false
    assert why["payload"]["reason"] == "blocked"
    assert Enum.any?(why["payload"]["blockers"], &(&1["kind"] == "paused"))

    resumed = call("mission.resume", %{"mission_id" => mission.id})
    assert resumed["ok"] == true

    why2 = call("mission.why", %{"mission_id" => mission.id})

    refute Enum.any?(
             why2["payload"]["blockers"],
             &(&1["kind"] == "paused" and &1["status"] == "open")
           )
  end

  test "review lists missions waiting on the boss" do
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())
    {:ok, _} = Missions.submit_for_authorization(mission.id, Actor.boss())

    resp = call("mission.review")
    assert resp["ok"] == true
    assert Enum.any?(resp["payload"]["missions"], &(&1["id"] == mission.id))
  end

  test "attempt.list, incident.list, event.list, and attempt.logs are read-only" do
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())

    {:ok, _} =
      Repo.insert(
        Consigliere.Incidents.Incident.changeset(%Consigliere.Incidents.Incident{}, %{
          mission_id: mission.id,
          severity: "warning",
          reason: "fixture-incident"
        })
      )

    attempts = call("attempt.list")
    assert attempts["ok"] == true
    assert is_list(attempts["payload"]["attempts"])

    incidents = call("incident.list")
    assert incidents["ok"] == true
    assert Enum.any?(incidents["payload"]["incidents"], &(&1["reason"] == "fixture-incident"))

    events = call("event.list")
    assert events["ok"] == true
    assert Enum.any?(events["payload"]["events"], &(&1["type"] == "mission.created"))

    attempt = Fixtures.attempt!(mission)

    log_path = Path.join(Home.logs_dir(), "attempts/#{attempt.id}.log")
    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, "hello from harness\n")

    logs = call("attempt.logs", %{"attempt_id" => attempt.id})
    assert logs["ok"] == true
    assert logs["payload"]["path"] == log_path
    assert Enum.any?(logs["payload"]["lines"], &(&1 =~ "hello from harness"))
  end

  test "reconcile is privileged and returns a result count" do
    denied =
      call("reconcile", %{}, %{
        "principal" => "attempt",
        "attempt_id" => "a",
        "fencing_token" => "f"
      })

    assert denied["error"]["code"] == "unauthorized"

    ok = call("reconcile")
    assert ok["ok"] == true
    assert is_integer(ok["payload"]["count"])
  end

  test "boss-only mutating ops fail on the capability-bound socket" do
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())

    resp =
      call(
        "mission.cancel",
        %{"mission_id" => mission.id, "reason" => "no"},
        %{"principal" => "attempt", "attempt_id" => "a", "fencing_token" => "f"},
        :capability
      )

    assert resp["ok"] == false
    assert resp["error"]["code"] == "unauthorized"
    assert Repo.get!(Consigliere.Missions.Mission, mission.id).phase == "draft"
  end
end
