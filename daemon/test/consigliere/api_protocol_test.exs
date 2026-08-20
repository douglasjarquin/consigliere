defmodule Consigliere.API.ProtocolTest do
  use ExUnit.Case, async: false

  alias Consigliere.API.Protocol
  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Fixtures
  alias Consigliere.Missions
  alias Consigliere.Questions

  setup do
    Fixtures.reset_phase1_tables!()
    Consigliere.GlobalScheduler.reset()
    :ok
  end

  defp decode(line) do
    {:ok, map} = JSON.decode(line)
    map
  end

  test "rejects a non-1 protocol version" do
    line =
      JSON.encode!(%{"v" => 99, "id" => "x", "op" => "ping", "actor" => %{"principal" => "boss"}})

    resp = decode(Protocol.handle(line))
    assert resp["ok"] == false
    assert resp["error"]["code"] == "protocol_version"
  end

  test "rejects a missing actor" do
    line = JSON.encode!(%{"v" => 1, "id" => "x", "op" => "ping"})
    resp = decode(Protocol.handle(line))
    assert resp["error"]["code"] == "unauthorized"
  end

  test "ping" do
    line =
      JSON.encode!(%{"v" => 1, "id" => "p1", "op" => "ping", "actor" => %{"principal" => "boss"}})

    resp = decode(Protocol.handle(line))
    assert resp["ok"] == true
    assert resp["payload"]["pong"] == true
  end

  test "boss can create, submit, and grant work; model_advisory cannot grant" do
    create =
      Protocol.handle(
        JSON.encode!(%{
          "v" => 1,
          "id" => "c",
          "op" => "mission.create",
          "actor" => %{"principal" => "boss"},
          "payload" => %{"objective" => "o", "scope" => "s", "acceptance_criteria" => "a"}
        })
      )

    %{"ok" => true, "payload" => %{"id" => id, "phase" => "draft"}} = decode(create)

    submit =
      Protocol.handle(
        JSON.encode!(%{
          "v" => 1,
          "id" => "s",
          "op" => "mission.submit",
          "actor" => %{"principal" => "boss"},
          "payload" => %{"mission_id" => id}
        })
      )

    assert decode(submit)["payload"]["phase"] == "awaiting_authorization"

    denied =
      Protocol.handle(
        JSON.encode!(%{
          "v" => 1,
          "id" => "g",
          "op" => "mission.grant_work",
          "actor" => %{"principal" => "model_advisory"},
          "payload" => %{"mission_id" => id}
        })
      )

    assert decode(denied)["error"]["code"] == "unauthorized"

    granted =
      Protocol.handle(
        JSON.encode!(%{
          "v" => 1,
          "id" => "g2",
          "op" => "mission.grant_work",
          "actor" => %{"principal" => "boss"},
          "payload" => %{"mission_id" => id}
        })
      )

    assert decode(granted)["payload"]["phase"] == "authorized"
  end

  test "attempt principal cannot answer a boss-authority Question" do
    {:ok, mission} =
      Missions.create(%{objective: "o", scope: "s", acceptance_criteria: "a"}, Actor.boss())

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Missions.grant_work_authorization(mission.id, Actor.boss())

    {:ok, %{attempt: attempt}} =
      Missions.start(mission.id, Actor.system(), %{
        workspace_path: "/tmp/cs-#{System.unique_integer([:positive])}"
      })

    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())

    {:ok, attempt} =
      Attempts.mark_running(attempt.id, Actor.system(), %{fencing_token: attempt.fencing_token})

    {:ok, question} =
      Questions.open(
        %{
          attempt_id: attempt.id,
          request_id: "r1",
          blocking_scope: "mission",
          requested_authority: "boss",
          prompt: "land?"
        },
        Actor.attempt(attempt.id, attempt.fencing_token)
      )

    denied =
      Protocol.handle(
        JSON.encode!(%{
          "v" => 1,
          "id" => "a",
          "op" => "question.answer",
          "actor" => %{
            "principal" => "attempt",
            "attempt_id" => attempt.id,
            "fencing_token" => attempt.fencing_token
          },
          "payload" => %{"question_id" => question.id, "answer" => "yes"}
        })
      )

    assert decode(denied)["error"]["code"] == "unauthorized"
    assert Consigliere.Repo.get!(Consigliere.Questions.Question, question.id).status == "open"

    ok =
      Protocol.handle(
        JSON.encode!(%{
          "v" => 1,
          "id" => "b",
          "op" => "question.answer",
          "actor" => %{"principal" => "boss"},
          "payload" => %{"question_id" => question.id, "answer" => "yes"}
        })
      )

    assert decode(ok)["payload"]["status"] == "answered"
  end

  test "inbox lists open questions for the boss" do
    {:ok, mission} =
      Missions.create(%{objective: "o", scope: "s", acceptance_criteria: "a"}, Actor.boss())

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Missions.grant_work_authorization(mission.id, Actor.boss())

    {:ok, %{attempt: attempt}} =
      Missions.start(mission.id, Actor.system(), %{
        workspace_path: "/tmp/cs-#{System.unique_integer([:positive])}"
      })

    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())

    {:ok, attempt} =
      Attempts.mark_running(attempt.id, Actor.system(), %{fencing_token: attempt.fencing_token})

    {:ok, _} =
      Questions.open(
        %{
          attempt_id: attempt.id,
          request_id: "inbox-1",
          blocking_scope: "mission",
          requested_authority: "boss",
          prompt: "choose"
        },
        Actor.attempt(attempt.id, attempt.fencing_token)
      )

    resp =
      Protocol.handle(
        JSON.encode!(%{
          "v" => 1,
          "id" => "i",
          "op" => "questions.inbox",
          "actor" => %{"principal" => "boss"}
        })
      )

    questions = decode(resp)["payload"]["questions"]
    assert Enum.any?(questions, &(&1["prompt"] == "choose"))
  end

  test "attempt and model_advisory cannot grant integration" do
    {:ok, mission} =
      Missions.create(%{objective: "o", scope: "s", acceptance_criteria: "a"}, Actor.boss())

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Missions.grant_work_authorization(mission.id, Actor.boss())

    {:ok, %{mission: mission}} =
      Missions.start(mission.id, Actor.system(), %{
        workspace_path: "/tmp/cs-#{System.unique_integer([:positive])}"
      })

    {:ok, _} =
      Consigliere.Repo.update(
        Consigliere.Missions.Mission.changeset(
          Consigliere.Repo.get!(Consigliere.Missions.Mission, mission.id),
          %{phase: "awaiting_integration_authorization", current_delivery_sha: "deliv"}
        )
      )

    payload = %{
      "mission_id" => mission.id,
      "target_sha" => "deliv",
      "target_pull_request" => "1"
    }

    denied_attempt =
      decode(
        Protocol.handle(
          JSON.encode!(%{
            "v" => 1,
            "id" => "g1",
            "op" => "mission.grant_integration",
            "actor" => %{"principal" => "attempt", "attempt_id" => "a", "fencing_token" => "f"},
            "payload" => payload
          })
        )
      )

    denied_model =
      decode(
        Protocol.handle(
          JSON.encode!(%{
            "v" => 1,
            "id" => "g2",
            "op" => "mission.grant_integration",
            "actor" => %{"principal" => "model_advisory"},
            "payload" => payload
          })
        )
      )

    granted =
      decode(
        Protocol.handle(
          JSON.encode!(%{
            "v" => 1,
            "id" => "g3",
            "op" => "mission.grant_integration",
            "actor" => %{"principal" => "boss"},
            "payload" => payload
          })
        )
      )

    assert denied_attempt["error"]["code"] == "unauthorized"
    assert denied_model["error"]["code"] == "unauthorized"
    assert granted["payload"]["phase"] == "integrating"
  end
end
