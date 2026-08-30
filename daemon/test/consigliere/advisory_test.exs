defmodule Consigliere.AdvisoryTest do
  use ExUnit.Case, async: false

  alias Consigliere.API.Protocol
  alias Consigliere.Actor
  alias Consigliere.CommandReceipts.CommandReceipt
  alias Consigliere.Fixtures
  alias Consigliere.Home
  alias Consigliere.Incidents.Incident
  alias Consigliere.MissionBlockers.MissionBlocker
  alias Consigliere.Missions
  alias Consigliere.Questions.Question
  alias Consigliere.Repo

  setup do
    Fixtures.reset_phase1_tables!()
    Consigliere.GlobalScheduler.reset()
    :ok
  end

  test "advisory orientation returns one bounded actionable snapshot without private paths" do
    project = Fixtures.dummy_project!()

    {:ok, mission} =
      Missions.create(
        Fixtures.mission_attrs(%{project_id: project.id, objective: "inspect the project"}),
        Actor.boss()
      )

    attempt = Fixtures.attempt!(mission)

    Repo.insert!(
      Question.changeset(%Question{}, %{
        mission_id: mission.id,
        attempt_id: attempt.id,
        request_id: "question-1",
        blocking_scope: "mission",
        requested_authority: "boss",
        status: "open",
        prompt: "review this bounded question",
        recommendation: "ask the boss"
      })
    )

    Repo.insert!(
      MissionBlocker.changeset(%MissionBlocker{}, %{
        mission_id: mission.id,
        kind: "question",
        status: "open",
        reason: "review this bounded question"
      })
    )

    Repo.insert!(
      Incident.changeset(%Incident{}, %{
        mission_id: mission.id,
        severity: "warning",
        reason: "bounded incident"
      })
    )

    response =
      advisory_call(
        "advisory.orient",
        %{
          "project_id" => project.id,
          "mission_id" => mission.id,
          "session_id" => "session-1",
          "turn" => 2,
          "compactions" => 1,
          "resets" => 0,
          "human_interventions" => 1,
          "input_tokens" => 11,
          "output_tokens" => 7,
          "cached_input_tokens" => 2
        }
      )

    assert response["ok"] == true
    snapshot = response["payload"]
    assert snapshot["snapshot_version"] == 1
    assert snapshot["filters"] == %{"project_id" => project.id, "mission_id" => mission.id}
    assert Enum.any?(snapshot["projects"], &(&1["id"] == project.id))
    assert Enum.any?(snapshot["missions"], &(&1["id"] == mission.id))
    assert Enum.any?(snapshot["questions"], &(&1["mission_id"] == mission.id))
    assert Enum.any?(snapshot["incidents"], &(&1["mission_id"] == mission.id))
    assert Enum.any?(snapshot["blockers"], &(&1["mission_id"] == mission.id))
    assert Enum.any?(snapshot["attention_requests"], &(&1["kind"] == "boss_question"))
    assert Enum.any?(snapshot["safe_next_actions"], &(&1["mission_id"] == mission.id))
    assert snapshot["ledger_status"] == "recorded"
    assert snapshot["snapshot_bytes"] <= Consigliere.V0.Limits.semantic_payload_bytes()

    forbidden_keys =
      snapshot
      |> all_keys()
      |> MapSet.new()

    for key <-
          ~w(database_path trusted_mirror_path repository_path workspace_path path argv lines transcript capability secret) do
      refute MapSet.member?(forbidden_keys, key), "advisory snapshot exposed #{key}"
    end

    ledger = File.read!(Home.advisory_ledger_path())
    assert ledger =~ "session-1"
    assert ledger =~ "snapshot_bytes"
    assert ledger =~ "human_interventions"
    refute ledger =~ Home.ensure_boss_secret!()
  end

  test "advisory can create a Mission draft but cannot perform Boss mutations" do
    project = Fixtures.dummy_project!()

    draft =
      advisory_call("mission.create", %{
        "project_id" => project.id,
        "objective" => "draft only",
        "scope" => "bounded",
        "acceptance_criteria" => "boss review"
      })

    assert draft["ok"] == true
    mission_id = draft["payload"]["id"]
    assert Repo.get!(Consigliere.Missions.Mission, mission_id).phase == "draft"

    before = Repo.aggregate(CommandReceipt, :count)

    for {op, payload} <- [
          {"mission.grant_work", %{"mission_id" => mission_id}},
          {"mission.cancel", %{"mission_id" => mission_id, "reason" => "injected"}},
          {"mission.pause", %{"mission_id" => mission_id}},
          {"mission.resume", %{"mission_id" => mission_id}},
          {"mission.continue",
           %{"mission_id" => mission_id, "checkpoint_sha" => String.duplicate("a", 40)}},
          {"mission.grant_integration",
           %{
             "mission_id" => mission_id,
             "target_sha" => String.duplicate("a", 40),
             "target_pull_request" => "1"
           }},
          {"question.answer", %{"question_id" => "missing", "answer" => "injected"}},
          {"attempt.logs", %{"attempt_id" => "missing"}},
          {"away.mark", %{}},
          {"reconcile", %{}},
          {"daemon.shutdown", %{}},
          {"project.add", %{"name" => "injected", "repository_path" => "/tmp/injected"}},
          {"question.open", %{"attempt_id" => "missing", "prompt" => "injected"}}
        ] do
      denied = advisory_call(op, payload)
      assert denied["ok"] == false
      assert denied["error"]["code"] == "unauthorized"
    end

    assert Repo.aggregate(CommandReceipt, :count) == before
    assert Repo.get!(Consigliere.Missions.Mission, mission_id).phase == "draft"
  end

  test "replaying Boss-shaped request bytes through advisory auth cannot upgrade authority" do
    project = Fixtures.dummy_project!()

    {:ok, mission} =
      Missions.create(
        Fixtures.mission_attrs(%{project_id: project.id}),
        Actor.boss()
      )

    request =
      JSON.encode!(%{
        "v" => 1,
        "id" => "boss-shaped",
        "op" => "mission.grant_work",
        "actor" => %{"principal" => "boss", "channel" => "privileged"},
        "secret" => Home.ensure_advisory_secret!(),
        "payload" => %{"mission_id" => mission.id}
      })

    response = Protocol.handle(request, :api) |> JSON.decode!()
    assert response["ok"] == false
    assert response["error"]["code"] == "unauthorized"
    assert Repo.get!(Consigliere.Missions.Mission, mission.id).phase == "draft"
    assert Repo.aggregate(CommandReceipt, :count) == 0
  end

  defp advisory_call(op, payload) do
    Protocol.handle(
      JSON.encode!(%{
        "v" => 1,
        "id" => "advisory-#{System.unique_integer([:positive])}",
        "op" => op,
        "actor" => %{"principal" => "model_advisory", "channel" => "advisory"},
        "secret" => Home.ensure_advisory_secret!(),
        "payload" => payload
      }),
      :api
    )
    |> JSON.decode!()
  end

  defp all_keys(map) when is_map(map) do
    Enum.reduce(map, MapSet.new(), fn {key, value}, keys ->
      keys
      |> MapSet.put(to_string(key))
      |> MapSet.union(all_keys(value))
    end)
  end

  defp all_keys(list) when is_list(list) do
    Enum.reduce(list, MapSet.new(), &MapSet.union(&2, all_keys(&1)))
  end

  defp all_keys(_value), do: MapSet.new()
end
