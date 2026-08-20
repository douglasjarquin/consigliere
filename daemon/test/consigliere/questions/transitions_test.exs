defmodule Consigliere.Questions.TransitionsTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Consigliere.Actor
  alias Consigliere.Fixtures
  alias Consigliere.Missions
  alias Consigliere.Attempts
  alias Consigliere.Questions
  alias Consigliere.Repo
  alias Consigliere.Questions.Question
  alias Consigliere.MissionBlockers.MissionBlocker
  alias Consigliere.OutboxItems.OutboxItem
  alias Consigliere.Incidents.Incident

  setup do
    Fixtures.reset_phase1_tables!()
    :ok
  end

  defp running! do
    {:ok, mission} =
      Missions.create(Fixtures.mission_attrs(), Actor.boss())

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Missions.grant_work_authorization(mission.id, Actor.boss())

    {:ok, %{attempt: attempt}} =
      Missions.start(mission.id, Actor.system(), %{
        workspace_path: "/tmp/cs-#{System.unique_integer([:positive])}"
      })

    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())

    {:ok, attempt} =
      Attempts.mark_running(attempt.id, Actor.system(), %{fencing_token: attempt.fencing_token})

    attempt
  end

  defp open_attrs(attempt, overrides) do
    Map.merge(
      %{
        attempt_id: attempt.id,
        request_id: "req-1",
        blocking_scope: "attempt",
        requested_authority: "boss",
        prompt: "which?"
      },
      overrides
    )
  end

  test "open is idempotent on (attempt_id, request_id) and writes one blocker and one event" do
    attempt = running!()
    actor = Actor.attempt(attempt.id, attempt.fencing_token)

    {:ok, first} = Questions.open(open_attrs(attempt, %{}), actor)
    {:ok, second} = Questions.open(open_attrs(attempt, %{}), actor)

    assert first.id == second.id
    assert Repo.aggregate(Question, :count) == 1
    assert Repo.aggregate(MissionBlocker, :count) == 1
    assert Fixtures.event_types(first.id) == ["question.opened"]
  end

  test "a gate-subject question does not open a question blocker" do
    attempt = running!()
    mission = Repo.get!(Consigliere.Missions.Mission, attempt.mission_id)

    {:ok, gate} =
      Consigliere.Gates.create(mission.id, Actor.system(), %{
        gate_type: "review",
        input_sha: "in",
        base_sha: "base",
        policy_hash: "p"
      })

    {:ok, question} =
      Questions.open(
        open_attrs(attempt, %{subject_type: "gate", subject_id: gate.id}),
        Actor.attempt(attempt.id, attempt.fencing_token)
      )

    assert question.subject_type == "gate"
    assert question.subject_id == gate.id
    assert Repo.aggregate(MissionBlocker, :count) == 0
  end

  test "a fenced attempt cannot open a question" do
    attempt = running!()

    assert {:error, {:fenced, _}} =
             Questions.open(open_attrs(attempt, %{}), Actor.attempt(attempt.id, "stale"))

    assert Repo.aggregate(Question, :count) == 0
  end

  test "two concurrent opens with the same request_id produce one row" do
    attempt = running!()
    actor = Actor.attempt(attempt.id, attempt.fencing_token)
    attrs = open_attrs(attempt, %{})

    results =
      1..2
      |> Task.async_stream(fn _ -> Questions.open(attrs, actor) end, timeout: 10_000)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert Repo.aggregate(Question, :count) == 1
  end

  test "boss can answer an open question without routing, producing no outbox row" do
    attempt = running!()

    {:ok, question} =
      Questions.open(open_attrs(attempt, %{}), Actor.attempt(attempt.id, attempt.fencing_token))

    {:ok, question} =
      Questions.answer(question.id, Actor.boss(), %{answer: "yes", answer_channel: "privileged"})

    assert question.status == "answered"
    assert Repo.aggregate(OutboxItem, :count) == 0
    blocker = Repo.one!(from(b in MissionBlocker, where: b.subject_id == ^question.id))
    assert blocker.status == "closed"
    assert blocker.closed_reason == "answered"
  end

  test "model_advisory cannot answer a boss-authority question" do
    attempt = running!()

    {:ok, question} =
      Questions.open(open_attrs(attempt, %{}), Actor.attempt(attempt.id, attempt.fencing_token))

    assert {:error, {:unauthorized, :boss_required}} =
             Questions.answer(question.id, Actor.model_advisory(), %{answer: "no"})

    assert Repo.get!(Question, question.id).status == "open"
  end

  test "route enqueues a notification outbox item; a second route is illegal" do
    attempt = running!()

    {:ok, question} =
      Questions.open(open_attrs(attempt, %{}), Actor.attempt(attempt.id, attempt.fencing_token))

    {:ok, question} = Questions.route(question.id, Actor.system())
    assert question.route == "boss_inbox"
    assert Repo.aggregate(OutboxItem, :count) == 1

    assert {:error, {:illegal_transition, _}} = Questions.route(question.id, Actor.system())
  end

  test "expire opens an incident and leaves the blocker open" do
    attempt = running!()

    {:ok, question} =
      Questions.open(open_attrs(attempt, %{}), Actor.attempt(attempt.id, attempt.fencing_token))

    {:ok, question} = Questions.expire(question.id, Actor.system())
    assert question.status == "expired"
    assert Repo.aggregate(Incident, :count) == 1
    blocker = Repo.one!(from(b in MissionBlocker, where: b.subject_id == ^question.id))
    assert blocker.status == "open"
  end

  test "supersede refuses a mission-scoped question" do
    attempt = running!()

    {:ok, question} =
      Questions.open(
        open_attrs(attempt, %{blocking_scope: "mission"}),
        Actor.attempt(attempt.id, attempt.fencing_token)
      )

    assert {:error, {:illegal_transition, %{reason: :mission_scoped}}} =
             Questions.supersede(question.id, Actor.system())
  end
end
