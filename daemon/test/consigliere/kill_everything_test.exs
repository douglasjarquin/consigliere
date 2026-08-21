defmodule Consigliere.KillEverythingTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.API.Protocol
  alias Consigliere.Attempts
  alias Consigliere.Away
  alias Consigliere.Fixtures
  alias Consigliere.Missions
  alias Consigliere.Questions
  alias Consigliere.Questions.Question
  alias Consigliere.Repo

  setup do
    Fixtures.reset_phase1_tables!()
    File.rm(Away.path())
    :ok
  end

  test "a boss Question survives daemon restart and only the boss channel can answer it" do
    {:ok, mission} =
      Missions.create(Fixtures.mission_attrs(), Actor.boss())

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Fixtures.grant_work_quietly(mission.id, Actor.boss())

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
          request_id: "kill-everything",
          blocking_scope: "mission",
          requested_authority: "boss",
          prompt: "merge?"
        },
        Actor.attempt(attempt.id, attempt.fencing_token)
      )

    {:ok, _} = Questions.route(question.id, Actor.system())
    Away.mark()

    question_id = question.id
    attempt_id = attempt.id
    token = attempt.fencing_token

    # The Question is a row, not a parked process. Killing the in-memory
    # coordinator (and any other Mission children) must not lose it.
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Consigliere.MissionDynamicSupervisor) do
      if is_pid(pid),
        do: DynamicSupervisor.terminate_child(Consigliere.MissionDynamicSupervisor, pid)
    end

    assert Repo.get!(Question, question_id).status == "routed"

    returned =
      decode(
        Protocol.handle(
          JSON.encode!(%{
            "v" => 1,
            "id" => "r",
            "op" => "away.return",
            "actor" => %{"principal" => "boss"}
          })
        )
      )

    assert returned["ok"] == true
    ids = Enum.map(returned["payload"]["questions"], & &1["id"])
    assert ids == [question_id]

    denied =
      decode(
        Protocol.handle(
          JSON.encode!(%{
            "v" => 1,
            "id" => "a",
            "op" => "question.answer",
            "actor" => %{
              "principal" => "attempt",
              "attempt_id" => attempt_id,
              "fencing_token" => token
            },
            "payload" => %{"question_id" => question_id, "answer" => "yes"}
          })
        )
      )

    assert denied["error"]["code"] == "unauthorized"
    assert Repo.get!(Question, question_id).status == "routed"

    advisory =
      decode(
        Protocol.handle(
          JSON.encode!(%{
            "v" => 1,
            "id" => "m",
            "op" => "question.answer",
            "actor" => %{"principal" => "model_advisory"},
            "payload" => %{"question_id" => question_id, "answer" => "yes"}
          })
        )
      )

    assert advisory["error"]["code"] == "unauthorized"

    ok =
      decode(
        Protocol.handle(
          JSON.encode!(%{
            "v" => 1,
            "id" => "b",
            "op" => "question.answer",
            "actor" => %{"principal" => "boss"},
            "payload" => %{"question_id" => question_id, "answer" => "yes"}
          })
        )
      )

    assert ok["payload"]["status"] == "answered"
  end

  defp decode(line) do
    {:ok, map} = JSON.decode(line)
    map
  end
end
