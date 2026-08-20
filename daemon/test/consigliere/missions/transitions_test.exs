defmodule Consigliere.Missions.TransitionsTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Fixtures
  alias Consigliere.Missions
  alias Consigliere.Missions.Mission
  alias Consigliere.Repo
  alias Consigliere.Gates.Gate
  alias Consigliere.Decisions.Decision

  setup do
    Fixtures.reset_phase1_tables!()
    :ok
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(Fixtures.mission_attrs(), overrides)
  end

  defp draft!(actor) do
    {:ok, mission} = Missions.create(attrs(), actor)
    mission
  end

  defp authorized! do
    mission = draft!(Actor.boss())
    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Missions.grant_work_authorization(mission.id, Actor.boss())
    mission
  end

  defp started! do
    mission = authorized!()

    {:ok, result} =
      Missions.start(mission.id, Actor.system(), %{
        workspace_path: "/tmp/cs-#{System.unique_integer([:positive])}"
      })

    result
  end

  test "create writes a draft mission and a mission.created event" do
    {:ok, mission} = Missions.create(attrs(), Actor.system())
    assert Repo.get(Mission, mission.id).phase == "draft"
    assert Fixtures.event_types(mission.id) == ["mission.created"]
  end

  test "create from an attempt principal is unauthorized" do
    assert {:error, {:unauthorized, :principal}} =
             Missions.create(attrs(), Actor.attempt("a", "f"))
  end

  test "submit then grant_work_authorization moves draft to authorized and records the Authorization" do
    mission = draft!(Actor.boss())
    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    assert mission.phase == "awaiting_authorization"

    {:ok, mission} = Missions.grant_work_authorization(mission.id, Actor.boss())
    assert mission.phase == "authorized"
    assert mission.authorization_id
    assert "mission.authorized" in Fixtures.event_types(mission.id)
  end

  test "grant_work_authorization from model_advisory is unauthorized" do
    mission = draft!(Actor.model_advisory())
    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.model_advisory())

    assert {:error, {:unauthorized, :principal}} =
             Missions.grant_work_authorization(mission.id, Actor.model_advisory())

    assert Repo.get(Mission, mission.id).phase == "awaiting_authorization"
  end

  test "submit from draft is refused when already authorized" do
    mission = authorized!()

    assert {:error, {:illegal_transition, %{reason: :wrong_phase}}} =
             Missions.submit_for_authorization(mission.id, Actor.boss())
  end

  test "request_changes returns awaiting_authorization to draft" do
    mission = draft!(Actor.boss())
    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Missions.request_changes(mission.id, Actor.boss())
    assert mission.phase == "draft"
    assert "mission.returned_to_draft" in Fixtures.event_types(mission.id)
  end

  test "start creates a workspace and a planned Attempt" do
    %{mission: mission, workspace: workspace, attempt: attempt} = started!()
    assert mission.phase == "active"
    assert mission.started_at
    assert workspace.status == "active"
    assert attempt.status == "planned"
    assert attempt.fencing_token
    assert "mission.started" in Fixtures.event_types(mission.id)
  end

  test "mark_ready_for_review requires a passed gate at the current checkpoint" do
    %{mission: mission} = started!()

    assert {:error, {:illegal_transition, %{reason: :missing_checkpoint}}} =
             Missions.mark_ready_for_review(mission.id, Actor.system())

    {:ok, _} =
      Repo.update(
        Mission.changeset(Repo.get!(Mission, mission.id), %{current_checkpoint_sha: "abc"})
      )

    {:ok, gate} =
      Repo.insert(
        Gate.changeset(%Gate{}, %{
          mission_id: mission.id,
          gate_type: "review",
          input_sha: "abc",
          base_sha: "base",
          policy_hash: "p",
          status: "passed"
        })
      )

    {:ok, ready} = Missions.mark_ready_for_review(mission.id, Actor.system())
    assert ready.phase == "ready_for_review"
    assert gate.id
  end

  test "integration authorization is tied to the exact delivery sha" do
    %{mission: mission} = started!()

    {:ok, _} =
      Repo.update(
        Mission.changeset(Repo.get!(Mission, mission.id), %{
          phase: "ready_for_review",
          current_checkpoint_sha: "abc"
        })
      )

    {:ok, mission} =
      Missions.await_integration_authorization(mission.id, Actor.system(), %{
        delivery_sha: "deliv"
      })

    assert {:error, {:illegal_transition, %{reason: :target_sha_mismatch}}} =
             Missions.grant_integration_authorization(mission.id, Actor.boss(), %{
               target_sha: "other",
               target_pull_request: "pr-1"
             })

    {:ok, mission} =
      Missions.grant_integration_authorization(mission.id, Actor.boss(), %{
        target_sha: "deliv",
        target_pull_request: "pr-1"
      })

    assert mission.phase == "integrating"

    {:ok, mission} =
      Missions.complete_integration(mission.id, Actor.system(), %{merged_sha: "merged"})

    assert mission.phase == "completed"
    assert mission.current_delivery_sha == "merged"
    assert "mission.completed" in Fixtures.event_types(mission.id)
  end

  test "detect_integration_race revokes authorization and opens a blocker" do
    %{mission: mission} = started!()

    {:ok, _} =
      Repo.update(
        Mission.changeset(Repo.get!(Mission, mission.id), %{
          phase: "integrating",
          current_delivery_sha: "deliv"
        })
      )

    {:ok, mission} = Missions.detect_integration_race(mission.id, Actor.system(), "head moved")
    assert mission.phase == "awaiting_integration_authorization"
    assert "mission.integration_race_detected" in Fixtures.event_types(mission.id)
  end

  test "cancel from boss is allowed; from model_advisory is not" do
    mission = draft!(Actor.boss())

    assert {:error, {:unauthorized, :principal}} =
             Missions.cancel(mission.id, Actor.model_advisory(), "nope")

    {:ok, mission} = Missions.cancel(mission.id, Actor.boss(), "stop")
    assert mission.phase == "canceled"

    assert {:error, {:illegal_transition, %{reason: :terminal}}} =
             Missions.cancel(mission.id, Actor.boss(), "again")
  end

  test "fail then resume_after_decision does not reset anything except phase" do
    mission = authorized!()
    {:ok, mission} = Missions.fail(mission.id, Actor.system(), %{terminal_reason: "budget"})
    assert mission.phase == "failed"

    {:ok, decision} =
      Repo.insert(
        Decision.changeset(%Decision{}, %{
          mission_id: mission.id,
          scope: "mission_finding_waiver",
          granted_by_principal: "boss"
        })
      )

    {:ok, mission} = Missions.resume_after_decision(mission.id, Actor.boss(), decision.id)
    assert mission.phase == "active"
    assert "mission.resumed_after_decision" in Fixtures.event_types(mission.id)
  end

  test "supersede creates a replacement with replaces_mission_id and marks the original superseded" do
    mission = authorized!()

    {:ok, %{mission: original, replacement: replacement}} =
      Missions.supersede(mission.id, Actor.boss(), attrs(%{objective: "replacement"}))

    assert original.phase == "superseded"
    assert replacement.replaces_mission_id == original.id
    assert "mission.superseded" in Fixtures.event_types(original.id)
  end
end
