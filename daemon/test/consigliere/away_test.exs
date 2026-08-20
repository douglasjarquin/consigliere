defmodule Consigliere.AwayTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Away
  alias Consigliere.CLI
  alias Consigliere.Fixtures
  alias Consigliere.Home
  alias Consigliere.Missions
  alias Consigliere.Questions

  import ExUnit.CaptureIO

  setup do
    Fixtures.reset_phase1_tables!()
    home = Home.dir()
    Home.ensure_dir!(home)
    File.rm(Away.path(home))
    :ok
  end

  defp open_boss_question! do
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
          request_id: "away-#{System.unique_integer([:positive])}",
          blocking_scope: "mission",
          requested_authority: "boss",
          prompt: "land it?"
        },
        Actor.attempt(attempt.id, attempt.fencing_token)
      )

    {:ok, question} = Questions.route(question.id, Actor.system())
    {attempt, question}
  end

  test "mark and return: digest lists each open Question once" do
    {_attempt, question} = open_boss_question!()
    assert Away.mark() == :ok
    assert Away.marked?()

    digest = Away.return()
    refute Away.marked?()
    ids = Enum.map(digest["questions"], & &1["id"])
    assert ids == [question.id]
  end

  test "CLI away then return prints the Question" do
    {_attempt, question} = open_boss_question!()
    assert capture_io(fn -> CLI.away() end) =~ "away"
    output = capture_io(fn -> CLI.return() end)
    assert output =~ "1 open question"
    assert output =~ question.id
    assert output =~ "land it?"
  end
end
