defmodule Consigliere.NotificationDispatcherTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Fixtures
  alias Consigliere.Home
  alias Consigliere.Missions
  alias Consigliere.NotificationDispatcher
  alias Consigliere.OutboxDispatcher
  alias Consigliere.OutboxItems.OutboxItem
  alias Consigliere.Questions
  alias Consigliere.Repo

  setup do
    Fixtures.reset_phase1_tables!()
    OutboxDispatcher.put_handler("notification", &NotificationDispatcher.deliver/1)
    log = Path.join(Home.dir(), "notifications.log")
    File.rm(log)
    {:ok, log: log}
  end

  test "a routed Question is notified without the Question depending on that delivery", %{log: log} do
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
          request_id: "n1",
          blocking_scope: "mission",
          requested_authority: "boss",
          prompt: "go?"
        },
        Actor.attempt(attempt.id, attempt.fencing_token)
      )

    {:ok, _} = Questions.route(question.id, Actor.system())
    assert {:ok, 1} = OutboxDispatcher.drain()
    assert Repo.get_by!(OutboxItem, natural_key: "question:" <> question.id).status == "completed"
    assert File.exists?(log)
    assert File.read!(log) =~ question.id
    assert Repo.get!(Consigliere.Questions.Question, question.id).status == "routed"
  end
end
