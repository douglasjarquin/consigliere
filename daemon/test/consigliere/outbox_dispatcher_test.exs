defmodule Consigliere.OutboxDispatcherTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Fixtures
  alias Consigliere.Missions
  alias Consigliere.Attempts
  alias Consigliere.Questions
  alias Consigliere.OutboxDispatcher
  alias Consigliere.OutboxItems.OutboxItem
  alias Consigliere.OutboxItems.Transitions
  alias Consigliere.Repo
  alias Consigliere.Txn
  alias Consigliere.DatabaseWriter

  setup do
    Fixtures.reset_phase1_tables!()
    OutboxDispatcher.clear_handlers()
    :ok
  end

  defp routed_question! do
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

    {:ok, question} =
      Questions.open(
        %{
          attempt_id: attempt.id,
          request_id: "req-#{System.unique_integer([:positive])}",
          blocking_scope: "mission",
          requested_authority: "boss",
          prompt: "which?"
        },
        Actor.attempt(attempt.id, attempt.fencing_token)
      )

    {:ok, question} = Questions.route(question.id, Actor.system())
    question
  end

  test "a successful handler completes the outbox row" do
    test = self()
    routed_question!()

    :ok =
      OutboxDispatcher.put_handler("notification", fn item ->
        send(test, {:dispatched, item.id})
        :ok
      end)

    assert {:ok, 1} = OutboxDispatcher.drain()
    assert_receive {:dispatched, id}, 1_000
    assert Repo.get!(OutboxItem, id).status == "completed"
  end

  test "a handler error retries the row with last_error and a future next_attempt_at" do
    routed_question!()

    :ok = OutboxDispatcher.put_handler("notification", fn _ -> {:error, "boom"} end)

    assert {:ok, 1} = OutboxDispatcher.drain()
    item = Repo.one!(OutboxItem)
    assert item.status == "queued"
    assert item.last_error == "boom"
    assert item.attempts == 1
    assert DateTime.compare(item.next_attempt_at, Txn.now()) == :gt

    assert {:ok, 0} = OutboxDispatcher.drain()
  end

  test "exhausting max_attempts marks the row failed" do
    routed_question!()
    :ok = OutboxDispatcher.put_handler("notification", fn _ -> {:error, "nope"} end)

    Enum.each(1..3, fn _ ->
      item = Repo.one!(OutboxItem)

      DatabaseWriter.transaction(fn ->
        Txn.update!(OutboxItem.changeset(item, %{next_attempt_at: Txn.now()}))
      end)

      OutboxDispatcher.drain()
    end)

    item = Repo.one!(OutboxItem)
    assert item.status == "failed"
    assert item.attempts == 3
    assert item.last_error == "nope"
  end

  test "an expired lease is reclaimed on the next drain" do
    test = self()
    routed_question!()
    now = Txn.now()
    past = DateTime.add(now, -1, :second)

    {:ok, leased} = Transitions.claim_due(["notification"], now, past)
    assert leased.status == "leased"

    :ok =
      OutboxDispatcher.put_handler("notification", fn item ->
        send(test, {:reclaimed, item.id})
        :ok
      end)

    assert {:ok, 1} = OutboxDispatcher.drain()
    assert_receive {:reclaimed, id}, 1_000
    assert id == leased.id
    assert Repo.get!(OutboxItem, id).status == "completed"
  end

  test "kinds without a handler stay queued" do
    routed_question!()
    assert {:ok, 0} = OutboxDispatcher.drain()
    assert Repo.one!(OutboxItem).status == "queued"
  end

  test "already_done from a destination-specific handler completes the row" do
    routed_question!()
    :ok = OutboxDispatcher.put_handler("notification", fn _ -> {:already_done, :exists} end)
    assert {:ok, 1} = OutboxDispatcher.drain()
    assert Repo.one!(OutboxItem).status == "completed"
  end
end
